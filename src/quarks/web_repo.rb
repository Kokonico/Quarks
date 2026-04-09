# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "uri"
require "openssl"
require "digest"
require "time"

module Quarks
  class WebRepoManager
    MAX_RETRIES = 5
    RETRY_DELAY_BASE = 2
    OFFLINE_GRACE_PERIOD = 86400
    CONNECT_TIMEOUT = 10
    READ_TIMEOUT = 60
    WRITE_TIMEOUT = 60

    FALLBACK_MIRRORS = {
      "ftp.gnu.org" => [
        "https://mirrors.kernel.org/gnu/",
        "https://ftpmirror1.internal.org/gnu/"
      ],
      "github.com" => [
        "https://mirror.ghproxy.com/https://github.com/"
      ],
      "raw.githubusercontent.com" => [
        "https://mirror.ghproxy.com/https://raw.githubusercontent.com/"
      ]
    }.freeze

    class RepoError < StandardError; end
    class SignatureError < RepoError; end
    class NetworkError < RepoError; end
    class ManifestExpiredError < RepoError; end
    class ChecksumError < RepoError; end

    class RepositoryMetadata
      attr_accessor :name, :repo_url, :priority, :enabled
      attr_accessor :gpg_key_id, :gpg_key_server, :gpg_key_url
      attr_accessor :manifest_url, :signature_url, :timestamp_url
      attr_accessor :last_sync, :manifest_etag, :manifest_mtime
      attr_accessor :manifest_data, :manifest_hash
      attr_accessor :mirrors, :verify_checksums, :allow_insecure

      def initialize(name:, repo_url:, **opts)
        @name = name
        @repo_url = repo_url
        @priority = opts[:priority] || 100
        @enabled = opts.fetch(:enabled, true)
        @gpg_key_id = opts[:gpg_key_id]
        @gpg_key_server = opts[:gpg_key_server]
        @gpg_key_url = opts[:gpg_key_url]
        @mirrors = opts[:mirrors] || []
        @verify_checksums = opts.fetch(:verify_checksums, true)
        @allow_insecure = opts.fetch(:allow_insecure, false)
        @manifest_url = opts[:manifest_url] || "#{repo_url.rstrip}/index.json"
        @signature_url = opts[:signature_url] || "#{repo_url.rstrip}/index.json.sig"
        @timestamp_url = opts[:timestamp_url] || "#{repo_url.rstrip}/timestamp.txt"
        @last_sync = nil
        @manifest_etag = nil
        @manifest_mtime = nil
        @manifest_data = nil
        @manifest_hash = nil
      end

      def expired?
        return false if @last_sync.nil?
        (Time.now - @last_sync) > OFFLINE_GRACE_PERIOD
      end

      def all_urls
        [@repo_url] + @mirrors
      end

      def to_h
        {
          name: @name,
          repo_url: @repo_url,
          priority: @priority,
          enabled: @enabled,
          gpg_key_id: @gpg_key_id,
          gpg_key_server: @gpg_key_server,
          gpg_key_url: @gpg_key_url,
          mirrors: @mirrors,
          verify_checksums: @verify_checksums,
          allow_insecure: @allow_insecure,
          manifest_url: @manifest_url,
          signature_url: @signature_url,
          timestamp_url: @timestamp_url,
          last_sync: @last_sync&.iso8601,
          manifest_etag: @manifest_etag,
          manifest_mtime: @manifest_mtime
        }
      end

      def self.from_h(h)
        m = new(
          name: h["name"],
          repo_url: h["repo_url"],
          priority: h["priority"],
          enabled: h.fetch("enabled", true)
        )
        m.gpg_key_id = h["gpg_key_id"]
        m.gpg_key_server = h["gpg_key_server"]
        m.gpg_key_url = h["gpg_key_url"]
        m.mirrors = h["mirrors"] || []
        m.verify_checksums = h.fetch("verify_checksums", true)
        m.allow_insecure = h.fetch("allow_insecure", false)
        m.manifest_url = h["manifest_url"]
        m.signature_url = h["signature_url"]
        m.timestamp_url = h["timestamp_url"]
        m.last_sync = h["last_sync"] ? Time.parse(h["last_sync"]) : nil
        m.manifest_etag = h["manifest_etag"]
        m.manifest_mtime = h["manifest_mtime"]
        m
      end
    end

    class << self
      def repo_config_dir
        dir = File.join(Quarks::Env.state_root, "var", "cache", "quarks", "repos")
        FileUtils.mkdir_p(dir)
        dir
      end

      def keyring_dir
        dir = File.join(Quarks::Env.state_root, "var", "cache", "quarks", "keys")
        FileUtils.mkdir_p(dir)
        dir
      end

      def distfiles_dir
        dir = File.join(Quarks::Env.state_root, "var", "cache", "quarks", "distfiles")
        FileUtils.mkdir_p(dir)
        dir
      end

      def load_repos
        config_file = File.join(repo_config_dir, "repositories.json")
        return {} unless File.exist?(config_file)

        begin
          data = JSON.parse(File.read(config_file))
          repos = {}
          data.each do |name, h|
            repos[name] = RepositoryMetadata.from_h(h.merge("name" => name))
          end
          repos
        rescue JSON::ParserError => e
          warn "[quarks] Invalid repository config: #{e.message}"
          {}
        end
      end

      def save_repos(repos)
        config_file = File.join(repo_config_dir, "repositories.json")
        data = repos.transform_values(&:to_h)
        File.write(config_file, JSON.pretty_generate(data))
      end

      def add_repo(name:, url:, priority: 100, gpg_key_id: nil, gpg_key_server: nil, gpg_key_url: nil, mirrors: [])
        repos = load_repos
        repo = RepositoryMetadata.new(
          name: name,
          repo_url: url,
          priority: priority,
          gpg_key_id: gpg_key_id,
          gpg_key_server: gpg_key_server,
          gpg_key_url: gpg_key_url,
          mirrors: mirrors
        )
        repos[name] = repo
        save_repos(repos)
        repo
      end

      def remove_repo(name)
        repos = load_repos
        removed = repos.delete(name)
        save_repos(repos)
        removed
      end

      def sync_repo(name, force: false, verify: true, offline_ok: false)
        repos = load_repos
        repo = repos[name]
        raise RepoError, "Repository not found: #{name}" unless repo

        cached_manifest = load_cached_manifest(name)

        if !force && cached_manifest && !repo.expired?
          manifest_data = cached_manifest
        else
          manifest_data = fetch_manifest(repo, use_cache: !force, verify: verify)
        end

        if manifest_data.nil? && !offline_ok
          raise NetworkError, "Failed to sync repository '#{name}' and offline mode is disabled"
        end

        if manifest_data
          cache_manifest(name, manifest_data, repo)
          repo.last_sync = Time.now
          save_repos(repos)
        end

        manifest_data
      end

      def sync_all(force: false, verify: true, offline_ok: true)
        repos = load_repos
        results = {}
        errors = []

        sorted_repos = repos.values.sort_by(&:priority)

        sorted_repos.each do |repo|
          next unless repo.enabled

          begin
            data = sync_repo(repo.name, force: force, verify: verify, offline_ok: offline_ok)
            results[repo.name] = { success: true, data: data }
          rescue => e
            results[repo.name] = { success: false, error: e.message }
            errors << "#{repo.name}: #{e.message}"
            warn "[quarks] Failed to sync repo '#{repo.name}': #{e.message}" unless offline_ok
          end
        end

        { results: results, errors: errors }
      end

      def fetch_manifest(repo, use_cache: true, verify: true)
        retries = MAX_RETRIES
        last_error = nil

        retries.times do |attempt|
          begin
            return _do_fetch_manifest(repo, use_cache: use_cache, verify: verify)
          rescue NetworkError => e
            last_error = e
            if attempt < retries - 1
              delay = RETRY_DELAY_BASE ** attempt
              warn "[quarks] Retry #{attempt + 1}/#{retries} for #{repo.name} after #{delay}s: #{e.message}"
              sleep(delay)
            end
          end
        end

        if use_cache
          cached = load_cached_manifest(repo.name)
          if cached
            warn "[quarks] Using stale cache for '#{repo.name}' due to network errors"
            return cached
          end
        end

        raise last_error || NetworkError, "Failed to fetch manifest after #{retries} attempts"
      end

      def _do_fetch_manifest(repo, use_cache: true, verify: true)
        manifest_url = repo.manifest_url

        if use_cache && !force_refresh?(repo)
          cached = load_cached_manifest(repo.name)
          return cached if cached
        end

        uri = URI.parse(manifest_url)
        raise "Invalid manifest URL: #{manifest_url}" unless uri.is_a?(URI::HTTP)

        headers = {}
        headers["If-None-Match"] = repo.manifest_etag if repo.manifest_etag && use_cache
        headers["If-Modified-Since"] = repo.manifest_mtime if repo.manifest_mtime && use_cache

        response = http_request_with_fallback(uri, repo, headers: headers)

        case response
        when Net::HTTPNotModified
          return load_cached_manifest(repo.name)
        when Net::HTTPSuccess
          body = response.body
          manifest_data = JSON.parse(body)
          repo.manifest_etag = response["ETag"]
          repo.manifest_mtime = response["Last-Modified"]

          if verify && (repo.gpg_key_id || ENV["QUARKS_VERIFY_REPOS"] == "1")
            signature = fetch_signature(repo)
            verify_manifest!(body, signature, repo)
          end

          manifest_data
        else
          raise NetworkError, "HTTP #{response.code} #{response.message}"
        end
      rescue JSON::ParserError => e
        raise NetworkError, "Invalid JSON manifest: #{e.message}"
      end

      def force_refresh?(repo)
        ENV["QUARKS_FORCE_SYNC"] == "1"
      end

      def fetch_signature(repo)
        sig_url = repo.signature_url
        uri = URI.parse(sig_url)

        response = http_request_with_fallback(uri, repo)
        case response
        when Net::HTTPSuccess
          response.body
        when Net::HTTPNotFound
          nil
        else
          raise NetworkError, "Failed to fetch signature: HTTP #{response.code}"
        end
      rescue => e
        warn "[quarks] Could not fetch signature for '#{repo.name}': #{e.message}"
        nil
      end

      def verify_manifest!(manifest_body, signature, repo)
        return unless signature

        keyring_path = load_or_fetch_gpg_key(repo)
        return unless keyring_path

        if verify_gpg_signature(signature, manifest_body, keyring_path, repo.gpg_key_id)
          return
        else
          raise SignatureError, "GPG signature verification failed for '#{repo.name}'"
        end
      end

      def load_or_fetch_gpg_key(repo)
        return nil unless repo.gpg_key_id || repo.gpg_key_server || repo.gpg_key_url

        keyring_path = File.join(keyring_dir, "#{repo.name}-keyring.gpg")

        return keyring_path if File.exist?(keyring_path) && !stale_key?(keyring_path)

        if repo.gpg_key_url
          fetch_gpg_key_from_url(repo.gpg_key_url, keyring_path)
        elsif repo.gpg_key_server
          fetch_gpg_key_from_server(repo.gpg_key_server, repo.gpg_key_id, keyring_path)
        end

        keyring_path if File.exist?(keyring_path)
      end

      def stale_key?(keyring_path)
        return true unless File.exist?(keyring_path)
        mtime = File.mtime(keyring_path)
        (Time.now - mtime) > 604800
      end

      def fetch_gpg_key_from_url(url, dest)
        uri = URI.parse(url)
        response = http_request(uri)
        return unless response.is_a?(Net::HTTPSuccess)

        File.write(dest, response.body)
        true
      rescue => e
        warn "[quarks] Failed to fetch GPG key from #{url}: #{e.message}"
        false
      end

      def fetch_gpg_key_from_server(server, key_id, dest)
        return unless command_exists?("gpg")

        cmd = "gpg --keyserver #{Shellwords.escape(server)} --recv-keys #{Shellwords.escape(key_id)} 2>/dev/null"
        system(cmd)

        cmd = "gpg --export #{Shellwords.escape(key_id)} > #{Shellwords.escape(dest)} 2>/dev/null"
        system(cmd)

        File.exist?(dest)
      rescue => e
        warn "[quarks] Failed to fetch GPG key from server: #{e.message}"
        false
      end

      def verify_gpg_signature(signature, data, keyring_path, expected_key_id)
        return false unless signature
        return false unless File.exist?(keyring_path)

        return false unless command_exists?("gpgv") || command_exists?("gpg")

        if command_exists?("gpgv")
          verify_with_gpgv(signature, data, keyring_path, expected_key_id)
        else
          verify_with_gpg(signature, data, keyring_path, expected_key_id)
        end
      end

      def verify_with_gpgv(signature, data, keyring_path, _expected_key_id)
        sig_file = Tempfile.new(["manifest", ".sig"])
        data_file = Tempfile.new(["manifest", ".json"])
        status_file = Tempfile.new(["gpgv", ".status"])

        begin
          sig_file.write(signature)
          sig_file.close
          data_file.write(data)
          data_file.close
          status_file.write("0\n")
          status_file.close

          cmd = [
            "gpgv",
            "--status-file", status_file.path,
            "--keyring", keyring_path,
            sig_file.path,
            data_file.path
          ]

          system(*cmd)
          status = File.read(status_file.path).lines
          status.any? { |line| line.include?("[GNUPG:] VALIDSIG") }
        ensure
          sig_file.unlink rescue nil
          data_file.unlink rescue nil
          status_file.unlink rescue nil
        end
      end

      def verify_with_gpg(signature, data, keyring_path, expected_key_id)
        sig_file = Tempfile.new(["manifest", ".sig"])
        data_file = Tempfile.new(["manifest", ".json"])

        begin
          sig_file.write(signature)
          sig_file.close
          data_file.write(data)
          data_file.close

          cmd = [
            "gpg",
            "--no-default-keyring",
            "--keyring", keyring_path,
            "--verify",
            sig_file.path,
            data_file.path
          ]

          output = `#{cmd.map { |c| Shellwords.escape(c) }.join(" ")} 2>&1`
          return false unless $?.success?

          if expected_key_id
            output.include?(expected_key_id)
          else
            true
          end
        ensure
          sig_file.unlink rescue nil
          data_file.unlink rescue nil
        end
      end

      def load_cached_manifest(name)
        cache_path = manifest_cache_path(name)
        return nil unless File.exist?(cache_path)

        begin
          JSON.parse(File.read(cache_path))
        rescue JSON::ParserError
          nil
        end
      end

      def cache_manifest(name, data, repo)
        cache_path = manifest_cache_path(name)
        FileUtils.mkdir_p(File.dirname(cache_path))
        File.write(cache_path, JSON.generate(data))

        meta_path = "#{cache_path}.meta"
        meta = {
          cached_at: Time.now.iso8601,
          repo_url: repo.repo_url,
          etag: repo.manifest_etag,
          mtime: repo.manifest_mtime,
          hash: Digest::SHA256.hexdigest(JSON.generate(data))
        }
        File.write(meta_path, JSON.generate(meta))
      end

      def manifest_cache_path(name)
        safe_name = name.gsub(/[^a-zA-Z0-9._-]/, "_")
        File.join(repo_config_dir, "#{safe_name}.json")
      end

      def http_request_with_fallback(uri, repo, headers: {}, method: "GET", body: nil)
        urls_to_try = build_url_list(uri, repo)
        last_error = nil

        urls_to_try.each do |try_uri|
          begin
            return http_request(try_uri, headers: headers, method: method, body: body)
          rescue => e
            last_error = e
            debug_log "Failed #{try_uri}: #{e.message}"
          end
        end

        raise NetworkError, "All mirrors failed for #{uri}. Last error: #{last_error&.message}"
      end

      def build_url_list(uri, repo)
        urls = []
        host = uri.host

        urls << uri

        repo.mirrors.each do |mirror|
          begin
            mirror_uri = URI.parse(mirror)
            path = uri.path.dup
            urls << mirror_uri.merge(path)
          rescue
            urls << URI.parse(mirror + uri.path)
          end
        end

        FALLBACK_MIRRORS.each do |pattern, fallbacks|
          if host&.include?(pattern)
            fallbacks.each do |fallback|
              begin
                base = URI.parse(fallback)
                path = uri.path.dup
                urls << base.merge(path)
              rescue
              end
            end
          end
        end

        urls.uniq
      end

      def http_request(uri, headers: {}, method: "GET", body: nil, timeout: nil)
        timeout ||= { connect: CONNECT_TIMEOUT, read: READ_TIMEOUT, write: WRITE_TIMEOUT }

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"

        if ENV["QUARKS_SSL_NO_VERIFY"] == "1" || uri.host == "localhost"
          http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        end

        http.open_timeout = timeout[:connect] || CONNECT_TIMEOUT
        http.read_timeout = timeout[:read] || READ_TIMEOUT
        http.write_timeout = timeout[:write] || WRITE_TIMEOUT

        http.max_retries = 0

        request_class = Net::HTTP.const_get(method.capitalize)
        request = request_class.new(uri, headers)
        request["User-Agent"] = "Quarks/#{Quarks::VERSION rescue 'dev'}"
        request["Accept"] = "application/json"
        request["Accept-Encoding"] = "gzip, deflate"

        if body
          request.body = body
          request["Content-Type"] = "application/json"
        end

        response = http.request(request)
        debug_log "HTTP #{response.code} for #{uri}"
        response
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
        raise NetworkError, "Timeout connecting to #{uri.host}: #{e.message}"
      rescue SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED => e
        raise NetworkError, "Connection error to #{uri.host}: #{e.message}"
      end

      def fetch_nuclei_recipe(repo_name, package_path, verify: true)
        repos = load_repos
        repo = repos[repo_name]
        raise RepoError, "Repository not found: #{repo_name}" unless repo

        recipe_url = "#{repo.repo_url.rstrip}/nuclei/#{package_path}.nuclei"

        retries = MAX_RETRIES
        retries.times do |attempt|
          begin
            uri = URI.parse(recipe_url)
            response = http_request_with_fallback(uri, repo)
            raise NetworkError, "HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

            content = response.body
            checksum = Digest::SHA256.hexdigest(content)

            if verify && ENV["QUARKS_VERIFY_RECIPES"] == "1"
              checksum_url = "#{recipe_url}.sha256"
              checksum_response = http_request(URI.parse(checksum_url))
              if checksum_response.is_a?(Net::HTTPSuccess)
                expected_checksum = checksum_response.body.strip.split.first
                raise ChecksumError, "Recipe checksum mismatch" unless checksum == expected_checksum
              end
            end

            return content
          rescue NetworkError => e
            if attempt < retries - 1
              delay = RETRY_DELAY_BASE ** attempt
              sleep(delay)
            else
              raise
            end
          end
        end
      end

      def download_source(url, expected_checksum: nil, algorithm: "sha256", verify: true)
        uri = URI.parse(url)
        filename = File.basename(uri.path)
        dest_path = File.join(distfiles_dir, filename)

        return dest_path if File.exist?(dest_path) && !verify

        Tempfile.create(["download", ".tmp"], distfiles_dir) do |tmp|
          tmp.binmode

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == "https"
          http.open_timeout = CONNECT_TIMEOUT
          http.read_timeout = READ_TIMEOUT

          http.request_get(uri.path) do |response|
            case response
            when Net::HTTPSuccess
              response.read_body do |chunk|
                tmp.write(chunk)
              end
            when Net::HTTPRedirection
              redirect_uri = URI.parse(response["location"])
              return download_source(redirect_uri.to_s, expected_checksum: expected_checksum, algorithm: algorithm, verify: verify)
            else
              raise NetworkError, "HTTP #{response.code} for #{url}"
            end
          end

          tmp.close

          if verify && expected_checksum
            actual = Digest.const_get(algorithm.upcase).file(tmp.path).hexdigest
            unless actual == expected_checksum.downcase
              raise ChecksumError, "Checksum mismatch for #{filename}\n  Expected: #{expected_checksum}\n  Actual:   #{actual}"
            end
            debug_log "Checksum verified for #{filename}"
          end

          FileUtils.mv(tmp.path, dest_path)
        end

        dest_path
      rescue => e
        debug_log "Download failed: #{e.message}"
        raise
      end

      def verify_source_checksum(file_path, expected_checksum, algorithm: "sha256")
        return true unless expected_checksum

        actual = Digest.const_get(algorithm.upcase).file(file_path).hexdigest
        actual == expected_checksum.downcase
      end

      def command_exists?(name)
        system("command -v #{Shellwords.escape(name)} >/dev/null 2>&1")
      end

      def debug_log(msg)
        return unless ENV["QUARKS_DEBUG"] == "1"
        warn "[quarks/debug] #{msg}"
      end
    end
  end
end
