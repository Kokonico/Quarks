# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "uri"
require "openssl"
require "digest"
require "time"
require "open3"
require "shellwords"
require "tempfile"
require "quarks/env"
require "quarks/security"

module Quarks
  class WebRepoManager
    MAX_RETRIES = 3
    RETRY_DELAY_BASE = 2
    OFFLINE_GRACE_PERIOD = 86400
    CONNECT_TIMEOUT = 10
    READ_TIMEOUT = 60
    WRITE_TIMEOUT = 60
    MAX_MANIFEST_BYTES = 16 * 1024 * 1024
    MAX_SIGNATURE_BYTES = 1024 * 1024
    MAX_CONFIG_BYTES = 1024 * 1024
    MAX_MANIFEST_PACKAGES = 100_000

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
      attr_accessor :manifest_sequence
      attr_accessor :mirrors, :verify_checksums, :allow_insecure

      def initialize(name:, repo_url:, **opts)
        @name = name
        supplied_url = repo_url.to_s.sub(%r{/+\z}, "")
        explicit_manifest = supplied_url.match?(/\.json\z/i)
        @repo_url = explicit_manifest ? supplied_url.sub(%r{/[^/]+\z}, "") : supplied_url
        @priority = opts[:priority] || 100
        @enabled = opts.fetch(:enabled, true)
        @gpg_key_id = opts[:gpg_key_id]
        @gpg_key_server = opts[:gpg_key_server]
        @gpg_key_url = opts[:gpg_key_url]
        @mirrors = opts[:mirrors] || []
        @verify_checksums = opts.fetch(:verify_checksums, true)
        @allow_insecure = opts.fetch(:allow_insecure, false)
        @manifest_url = opts[:manifest_url] || (explicit_manifest ? supplied_url : "#{@repo_url}/index.json")
        @signature_url = opts[:signature_url] || "#{@manifest_url}.sig"
        @timestamp_url = opts[:timestamp_url] || "#{@repo_url}/timestamp.txt"
        @last_sync = nil
        @manifest_etag = nil
        @manifest_mtime = nil
        @manifest_data = nil
        @manifest_hash = nil
        @manifest_sequence = opts[:manifest_sequence]
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
          manifest_mtime: @manifest_mtime,
          manifest_sequence: @manifest_sequence
        }
      end

      def self.from_h(h)
        raise RepoError, "Repository entry must be a JSON object" unless h.is_a?(Hash)

        h = h.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
        name = h["name"].to_s
        raise RepoError, "Invalid repository name" unless name.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
        priority = Integer(h.fetch("priority", 100), exception: false)
        raise RepoError, "Repository priority must be between 0 and 10,000" unless priority&.between?(0, 10_000)
        enabled = h.fetch("enabled", true)
        allow_insecure = h.fetch("allow_insecure", false)
        verify_checksums = h.fetch("verify_checksums", true)
        unless [enabled, allow_insecure, verify_checksums].all? { |value| value == true || value == false }
          raise RepoError, "Repository booleans must be true or false"
        end
        mirrors = h.fetch("mirrors", [])
        raise RepoError, "Repository mirrors must be an array" unless mirrors.is_a?(Array)
        raise RepoError, "Repository has too many mirrors" if mirrors.length > 32
        raise RepoError, "Repository mirror URLs must be strings" unless mirrors.all? { |value| value.is_a?(String) }

        m = new(
          name: name,
          repo_url: h["repo_url"],
          priority: priority,
          enabled: enabled
        )
        m.gpg_key_id = h["gpg_key_id"]
        m.gpg_key_server = h["gpg_key_server"]
        m.gpg_key_url = h["gpg_key_url"]
        m.mirrors = mirrors
        m.verify_checksums = verify_checksums
        m.allow_insecure = allow_insecure
        m.manifest_url = h["manifest_url"] unless h["manifest_url"].to_s.empty?
        m.signature_url = h["signature_url"] unless h["signature_url"].to_s.empty?
        m.timestamp_url = h["timestamp_url"] unless h["timestamp_url"].to_s.empty?
        m.last_sync = h["last_sync"] ? Time.parse(h["last_sync"]) : nil
        m.manifest_etag = h["manifest_etag"]
        m.manifest_mtime = h["manifest_mtime"]
        m.manifest_sequence = h["manifest_sequence"]
        m
      end
    end

    class << self
      def repo_config_dir
        dir = File.join(Quarks::Env.state_root, "var", "cache", "quarks", "repos")
        Security.secure_directory(dir)
      end

      def keyring_dir
        dir = File.join(Quarks::Env.state_root, "var", "cache", "quarks", "keys")
        Security.secure_directory(dir)
      end

      def distfiles_dir
        dir = File.join(Quarks::Env.state_root, "var", "cache", "quarks", "distfiles")
        Security.secure_directory(dir)
      end

      def load_repos
        config_file = File.join(repo_config_dir, "repositories.json")
        return {} unless File.exist?(config_file)

        begin
          stat = File.lstat(config_file)
          raise RepoError, "Repository config must be a regular file" unless stat.file? && !stat.symlink?
          raise RepoError, "Repository config is group/world writable" if (stat.mode & 0o022).positive?
          raise RepoError, "Repository config exceeds #{MAX_CONFIG_BYTES} bytes" if stat.size > MAX_CONFIG_BYTES
          data = JSON.parse(File.read(config_file))
          raise RepoError, "Repository config must contain a JSON object" unless data.is_a?(Hash)
          repos = {}
          data.each do |name, h|
            raise RepoError, "Repository '#{name}' entry must be a JSON object" unless h.is_a?(Hash)
            repos[name] = RepositoryMetadata.from_h(h.merge("name" => name))
          end
          repos
        rescue JSON::ParserError => e
          raise RepoError, "Invalid repository config: #{e.message}"
        rescue ArgumentError, TypeError => e
          raise RepoError, "Invalid repository config: #{e.message}"
        end
      end

      def save_repos(repos)
        config_file = File.join(repo_config_dir, "repositories.json")
        data = repos.transform_values(&:to_h)
        Security.atomic_write(config_file, JSON.pretty_generate(data))
      end

      def add_repo(name:, url:, priority: 100, gpg_key_id: nil, gpg_key_server: nil, gpg_key_url: nil, mirrors: [], allow_insecure: false)
        raise RepoError, "Invalid repository name" unless name.to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/)
        priority = Integer(priority, exception: false)
        raise RepoError, "Repository priority must be between 0 and 10,000" unless priority&.between?(0, 10_000)
        if allow_insecure && ENV["QUARKS_ALLOW_UNSIGNED_REPOS"] != "1"
          raise SignatureError, "Unsigned repositories require QUARKS_ALLOW_UNSIGNED_REPOS=1"
        end
        Security.validate_remote_uri!(
          url,
          purpose: "repository manifest",
          allow_http: allow_insecure && ENV["QUARKS_ALLOW_INSECURE_REPOS"] == "1",
          allow_private: ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
        )
        unless allow_insecure
          fingerprint = normalize_key_id(gpg_key_id)
          raise SignatureError, "A complete 40- or 64-hex signing-key fingerprint is required" unless [40, 64].include?(fingerprint.length)
          raise SignatureError, "Keyserver acquisition is disabled; use an HTTPS signing-key URL" unless gpg_key_server.to_s.empty?
          raise SignatureError, "An HTTPS signing-key URL is required" if gpg_key_url.to_s.empty?
          Security.validate_remote_uri!(
            gpg_key_url,
            purpose: "repository signing key",
            allow_http: false,
            allow_private: ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
          )
        end

        repos = load_repos
        repo = RepositoryMetadata.new(
          name: name,
          repo_url: url,
          priority: priority,
          gpg_key_id: gpg_key_id,
          gpg_key_server: gpg_key_server,
          gpg_key_url: gpg_key_url,
          mirrors: mirrors,
          allow_insecure: allow_insecure
        )
        repos[name] = repo
        save_repos(repos)
        repo
      end

      def remove_repo(name)
        repos = load_repos
        removed = repos.delete(name)
        save_repos(repos)
        if removed
          cache_path = manifest_cache_path(name)
          FileUtils.rm_f(cache_path)
          FileUtils.rm_f("#{cache_path}.sig")
          FileUtils.rm_f("#{cache_path}.meta")
          safe_name = name.to_s.gsub(/[^a-zA-Z0-9._-]/, "_")
          FileUtils.rm_f(File.join(keyring_dir, "#{safe_name}-keyring.gpg"))
        end
        removed
      end

      def sync_repo(name, force: false, verify: true, offline_ok: false)
        raise SignatureError, "Repository signature verification cannot be disabled" unless verify
        repos = load_repos
        repo = repos[name]
        raise RepoError, "Repository not found: #{name}" unless repo
        if repo.allow_insecure && ENV["QUARKS_ALLOW_UNSIGNED_REPOS"] != "1"
          raise SignatureError, "Unsigned repository '#{name}' is disabled; set QUARKS_ALLOW_UNSIGNED_REPOS=1 explicitly"
        end

        cached_manifest = begin
          load_cached_manifest(name, repo: repo, verify: verify)
        rescue RepoError => e
          debug_log "Ignoring unusable cache for #{name}: #{e.message}"
          nil
        end
        fetched = false

        if !force && cached_manifest && !repo.expired?
          manifest_data = cached_manifest
        else
          manifest_data = fetch_manifest(repo, use_cache: !force, verify: verify)
          fetched = true
        end

        if manifest_data.nil? && !offline_ok
          raise NetworkError, "Failed to sync repository '#{name}' and offline mode is disabled"
        end

        if manifest_data && fetched
          cache_manifest(name, manifest_data, repo)
          repo.last_sync = Time.now
          save_repos(repos)
        end

        manifest_data
      end

      def sync_all(force: false, verify: true, offline_ok: true)
        raise SignatureError, "Repository signature verification cannot be disabled" unless verify
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
        raise SignatureError, "Repository signature verification cannot be disabled" unless verify
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
          cached = load_cached_manifest(repo.name, repo: repo, verify: true)
          if cached
            warn "[quarks] Using stale cache for '#{repo.name}' due to network errors"
            return cached
          end
        end

        raise last_error || NetworkError, "Failed to fetch manifest after #{retries} attempts"
      end

      def _do_fetch_manifest(repo, use_cache: true, verify: true)
        raise SignatureError, "Repository signature verification cannot be disabled" unless verify
        manifest_url = repo.manifest_url

        use_cache = false unless File.exist?(manifest_cache_path(repo.name))

        uri = URI.parse(manifest_url)
        raise "Invalid manifest URL: #{manifest_url}" unless uri.is_a?(URI::HTTP)

        headers = {}
        headers["If-None-Match"] = repo.manifest_etag if repo.manifest_etag && use_cache
        headers["If-Modified-Since"] = repo.manifest_mtime if repo.manifest_mtime && use_cache

        response = http_request_with_fallback(uri, repo, headers: headers, max_bytes: MAX_MANIFEST_BYTES)

        case response
        when Net::HTTPNotModified
          cached = load_cached_manifest(repo.name, repo: repo, verify: verify)
          raise NetworkError, "Repository returned 304 but no valid cache exists" unless cached

          cache_path = manifest_cache_path(repo.name)
          repo.manifest_data = File.binread(cache_path)
          sig_path = "#{cache_path}.sig"
          repo.manifest_hash = File.binread(sig_path) if File.exist?(sig_path)
          return cached
        when Net::HTTPSuccess
          body = response.body
          raise NetworkError, "Manifest exceeds 16 MiB" if body.bytesize > MAX_MANIFEST_BYTES
          manifest_data = JSON.parse(body)
          repo.manifest_etag = response["ETag"]
          repo.manifest_mtime = response["Last-Modified"]

          if verify && !repo.allow_insecure
            raise SignatureError, "Repository '#{repo.name}' has no pinned GPG fingerprint" if repo.gpg_key_id.to_s.empty?
            signature = fetch_signature(repo)
            verify_manifest!(body, signature, repo)
            repo.manifest_hash = signature
          end
          validate_manifest_metadata!(manifest_data, repo) unless repo.allow_insecure
          repo.manifest_data = body

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

        response = http_request_with_fallback(uri, repo, max_bytes: MAX_SIGNATURE_BYTES)
        case response
        when Net::HTTPSuccess
          body = response.body.to_s
          raise NetworkError, "Repository signature exceeds 1 MiB" if body.bytesize > MAX_SIGNATURE_BYTES
          body
        when Net::HTTPNotFound
          raise SignatureError, "Repository '#{repo.name}' has no detached signature"
        else
          raise NetworkError, "Failed to fetch signature: HTTP #{response.code}"
        end
      end

      def verify_manifest!(manifest_body, signature, repo)
        raise SignatureError, "Missing repository signature for '#{repo.name}'" if signature.to_s.empty?

        keyring_path = load_or_fetch_gpg_key(repo)
        raise SignatureError, "No trusted keyring is available for '#{repo.name}'" unless keyring_path

        if verify_gpg_signature(signature, manifest_body, keyring_path, repo.gpg_key_id)
          return
        else
          raise SignatureError, "GPG signature verification failed for '#{repo.name}'"
        end
      end

      def load_or_fetch_gpg_key(repo)
        expected = normalize_key_id(repo.gpg_key_id)
        raise SignatureError, "A complete GPG fingerprint is required for '#{repo.name}'" unless [40, 64].include?(expected.length)

        safe_name = repo.name.to_s.gsub(/[^a-zA-Z0-9._-]/, "_")
        keyring_path = File.join(keyring_dir, "#{safe_name}-keyring.gpg")

        return keyring_path if File.exist?(keyring_path) && keyring_contains?(keyring_path, expected)

        if repo.gpg_key_url
          fetch_gpg_key_from_url(repo.gpg_key_url, keyring_path, expected)
        elsif repo.gpg_key_server
          raise SignatureError, "Keyserver acquisition is disabled; configure an HTTPS signing-key URL"
        else
          raise SignatureError, "Trusted key for '#{repo.name}' is not installed; configure --gpg-key-url or a keyserver"
        end

        raise SignatureError, "Fetched key does not match pinned fingerprint #{expected}" unless keyring_contains?(keyring_path, expected)
        keyring_path
      end

      def fetch_gpg_key_from_url(url, dest, expected)
        uri = Security.validate_remote_uri!(
          url,
          purpose: "repository signing key",
          allow_http: false,
          allow_private: ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
        )
        response = http_request(uri, max_bytes: MAX_SIGNATURE_BYTES)
        raise NetworkError, "Could not download repository signing key" unless response.is_a?(Net::HTTPSuccess)
        raise SignatureError, "Repository signing key exceeds 1 MiB" if response.body.to_s.bytesize > 1024 * 1024

        import_gpg_key(response.body, dest, expected)
      end

      def fetch_gpg_key_from_server(server, key_id, dest)
        raise SignatureError, "Keyserver acquisition is disabled; use an HTTPS signing-key URL"
      end

      def import_gpg_key(key_data, dest, expected)
        gpg = trusted_command("gpg")
        raise SignatureError, "A trusted system gpg executable is required" unless gpg

        key_file = Tempfile.new(["quarks-repo-key", ".asc"])
        candidate = "#{dest}.candidate-#{Process.pid}"
        begin
          key_file.binmode
          key_file.write(key_data)
          key_file.close
          FileUtils.rm_f(candidate)
          _out, err, status = Open3.capture3(
            restricted_process_environment,
            gpg, "--no-options", "--batch", "--homedir", keyring_dir,
            "--no-default-keyring", "--keyring", candidate, "--import", key_file.path,
            unsetenv_others: true
          )
          raise SignatureError, "Could not import repository key: #{err.strip}" unless status.success?
          raise SignatureError, "Imported key does not match pinned fingerprint #{expected}" unless keyring_contains?(candidate, expected)

          File.chmod(0o600, candidate)
          File.rename(candidate, dest)
          true
        ensure
          key_file.unlink rescue nil
          FileUtils.rm_f(candidate) if File.exist?(candidate)
        end
      end

      def keyring_contains?(keyring_path, expected)
        gpg = trusted_command("gpg")
        return false unless File.exist?(keyring_path) && gpg

        output, _error, status = Open3.capture3(
          restricted_process_environment,
          gpg, "--no-options", "--batch", "--homedir", keyring_dir,
          "--no-default-keyring", "--keyring", keyring_path, "--with-colons", "--fingerprint",
          unsetenv_others: true
        )
        return false unless status.success?

        wanted = normalize_key_id(expected)
        output.lines.any? do |line|
          fields = line.split(":")
          fields[0] == "fpr" && normalize_key_id(fields[9]) == wanted
        end
      end

      def normalize_key_id(value)
        value.to_s.upcase.delete_prefix("0X").gsub(/[^0-9A-F]/, "")
      end

      def verify_gpg_signature(signature, data, keyring_path, expected_key_id)
        return false unless signature
        return false unless File.exist?(keyring_path)

        return false unless trusted_command("gpgv")
        verify_with_gpgv(signature, data, keyring_path, expected_key_id)
      end

      def verify_with_gpgv(signature, data, keyring_path, expected_key_id)
        sig_file = Tempfile.new(["manifest", ".sig"])
        data_file = Tempfile.new(["manifest", ".json"])

        begin
          sig_file.write(signature)
          sig_file.close
          data_file.write(data)
          data_file.close
          output, _error, status = Open3.capture3(
            restricted_process_environment,
            trusted_command("gpgv"), "--status-fd", "1", "--keyring", keyring_path,
            sig_file.path, data_file.path,
            unsetenv_others: true
          )
          return false unless status.success?
          valid_signature_fingerprint?(output, expected_key_id)
        ensure
          sig_file.unlink rescue nil
          data_file.unlink rescue nil
        end
      end

      def valid_signature_fingerprint?(status_output, expected_key_id)
        wanted = normalize_key_id(expected_key_id)
        return false unless [40, 64].include?(wanted.length)

        line = status_output.to_s.lines.find { |entry| entry.start_with?("[GNUPG:] VALIDSIG ") }
        return false unless line
        fingerprints = line.split.select { |field| field.match?(/\A[0-9A-Fa-f]{40}(?:[0-9A-Fa-f]{24})?\z/) }
        fingerprints.any? { |fingerprint| normalize_key_id(fingerprint) == wanted }
      end

      def load_cached_manifest(name, repo: nil, verify: true)
        raise SignatureError, "Repository signature verification cannot be disabled" unless verify
        cache_path = manifest_cache_path(name)
        return nil unless File.exist?(cache_path)

        begin
          body = File.read(cache_path)
          if repo && verify && !repo.allow_insecure
            sig_path = "#{cache_path}.sig"
            raise SignatureError, "Trusted cached manifest is missing its signature" unless File.exist?(sig_path)
            verify_manifest!(body, File.binread(sig_path), repo)
          end
          data = JSON.parse(body)
          validate_manifest_metadata!(data, repo) if repo && !repo.allow_insecure
          data
        rescue JSON::ParserError
          nil
        end
      end

      def cache_manifest(name, data, repo)
        cache_path = manifest_cache_path(name)
        FileUtils.mkdir_p(File.dirname(cache_path))
        body = repo.manifest_data || JSON.generate(data)
        Security.atomic_write(cache_path, body)
        if repo.manifest_hash
          Security.atomic_write("#{cache_path}.sig", repo.manifest_hash)
        elsif !repo.allow_insecure
          raise SignatureError, "Refusing to cache an unsigned trusted repository"
        end

        meta_path = "#{cache_path}.meta"
        meta = {
          cached_at: Time.now.iso8601,
          repo_url: repo.repo_url,
          etag: repo.manifest_etag,
          mtime: repo.manifest_mtime,
          hash: Digest::SHA256.hexdigest(JSON.generate(data))
        }
        Security.atomic_write(meta_path, JSON.generate(meta))
      end

      def manifest_cache_path(name)
        safe_name = name.gsub(/[^a-zA-Z0-9._-]/, "_")
        File.join(repo_config_dir, "#{safe_name}.json")
      end

      def validate_manifest_metadata!(manifest, repo)
        raise SignatureError, "Repository manifest must be a JSON object" unless manifest.is_a?(Hash)
        raise SignatureError, "Unsupported repository schema" unless manifest["schema_version"].to_i == 2
        raise SignatureError, "Repository manifest is missing packages" unless manifest["packages"].is_a?(Array)
        if manifest["packages"].length > MAX_MANIFEST_PACKAGES
          raise SignatureError, "Repository manifest contains too many packages"
        end

        sequence = Integer(manifest["sequence"], exception: false)
        raise SignatureError, "Repository manifest has an invalid sequence" unless sequence && sequence >= 0
        previous = Integer(repo.manifest_sequence, exception: false)
        if previous && sequence < previous
          raise SignatureError, "Repository manifest rollback detected (#{sequence} < #{previous})"
        end

        generated_at = Time.iso8601(manifest.fetch("generated_at"))
        expires_at = Time.iso8601(manifest.fetch("expires_at"))
        now = Time.now
        raise ManifestExpiredError, "Repository manifest was generated in the future" if generated_at > now + 300
        raise ManifestExpiredError, "Repository manifest expired at #{expires_at.iso8601}" if expires_at <= now
        raise SignatureError, "Repository manifest validity exceeds 30 days" if expires_at > generated_at + (30 * 86_400)

        repo.manifest_sequence = sequence
        true
      rescue KeyError, ArgumentError, TypeError => e
        raise SignatureError, "Invalid repository freshness metadata: #{e.message}"
      end

      def http_request_with_fallback(uri, repo, headers: {}, max_bytes: MAX_MANIFEST_BYTES)
        urls_to_try = build_url_list(uri, repo)
        last_error = nil

        urls_to_try.each do |try_uri|
          begin
            try_uri = Security.validate_remote_uri!(
              try_uri,
              purpose: "repository endpoint",
              allow_http: repo.allow_insecure && ENV["QUARKS_ALLOW_INSECURE_REPOS"] == "1",
              allow_private: ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
            )
            return http_request(try_uri, headers: headers, max_bytes: max_bytes)
          rescue => e
            last_error = e
            debug_log "Failed #{try_uri}: #{e.message}"
          end
        end

        raise NetworkError, "All mirrors failed for #{uri}. Last error: #{last_error&.message}"
      end

      def build_url_list(uri, repo)
        urls = []

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

        urls.uniq
      end

      def http_request(uri, headers: {}, timeout: nil, max_bytes: MAX_MANIFEST_BYTES)
        timeout ||= { connect: CONNECT_TIMEOUT, read: READ_TIMEOUT, write: WRITE_TIMEOUT }

        uri = Security.validate_remote_uri!(
          uri,
          purpose: "remote resource",
          allow_http: ENV["QUARKS_ALLOW_INSECURE_REPOS"] == "1",
          allow_private: ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
        )

        http = Net::HTTP.new(uri.host, uri.port)
        addresses = if ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
                      Resolv.getaddresses(uri.host)
                    else
                      Security.resolve_public_addresses!(uri.host, purpose: "remote resource")
                    end
        raise NetworkError, "Remote host did not resolve: #{uri.host}" if addresses.empty?
        http.ipaddr = addresses.first
        http.use_ssl = uri.scheme == "https"
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?

        http.open_timeout = timeout[:connect] || CONNECT_TIMEOUT
        http.read_timeout = timeout[:read] || READ_TIMEOUT
        http.write_timeout = timeout[:write] || WRITE_TIMEOUT

        http.max_retries = 0

        request = Net::HTTP::Get.new(uri, headers)
        request["User-Agent"] = "Quarks/#{Quarks::VERSION rescue 'dev'}"
        request["Accept"] = "application/json"
        response = nil
        http.request(request) do |incoming|
          response = incoming
          next unless incoming.is_a?(Net::HTTPSuccess)

          declared = Integer(incoming["Content-Length"], exception: false)
          raise NetworkError, "Remote response exceeds #{max_bytes} bytes" if declared && declared > max_bytes
          buffer = +"".b
          incoming.read_body do |chunk|
            raise NetworkError, "Remote response exceeds #{max_bytes} bytes" if buffer.bytesize + chunk.bytesize > max_bytes
            buffer << chunk
          end
          incoming.instance_variable_set(:@body, buffer)
        end
        debug_log "HTTP #{response.code} for #{uri}"
        response
      rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout => e
        raise NetworkError, "Timeout connecting to #{uri.host}: #{e.message}"
      rescue SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED => e
        raise NetworkError, "Connection error to #{uri.host}: #{e.message}"
      end

      def trusted_command(name)
        %W[/usr/bin/#{name} /bin/#{name}].find do |path|
          File.file?(path) && File.executable?(path)
        end
      end

      def restricted_process_environment
        { "PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C" }
      end

      def debug_log(msg)
        return unless ENV["QUARKS_DEBUG"] == "1"
        warn "[quarks/debug] #{msg}"
      end
    end
  end
end
