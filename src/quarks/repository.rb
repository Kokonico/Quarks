# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "net/http"
require "uri"
require "quarks/env"
require "quarks/package"
require "quarks/security"
require "quarks/web_repo"

module Quarks
  class Repository
    class DuplicatePackageError < StandardError; end

    Source = Struct.new(:type, :location, :name, keyword_init: true)

    class << self
      def project_root
        src_dir = File.expand_path("../..", __FILE__)
        if src_dir.end_with?("/src/quarks")
          File.expand_path("../..", src_dir)
        elsif src_dir.end_with?("/src")
          File.expand_path("..", src_dir)
        else
          src_dir
        end
      end
    end

    PROJECT_ROOT = project_root.freeze

    attr_reader :sources, :quarantined

    def initialize(custom_sources = nil)
      @cache_by_atom = {}
      @cache_by_name = {}
      @source_by_atom = {}
      @source_by_name = {}
      @blockers_by_target = {}
      @sorted_atoms = nil
      @errors = []
      @warnings = []
      @quarantined = []
      @scanned = false
      @sources = normalize_sources(custom_sources || default_sources)
      scan_all
    end

    def paths
      @sources.select { |s| s.type == :local }.map(&:location)
    end

    def errors
      @errors.dup
    end

    def warnings
      @warnings.dup
    end

    def default_sources
      local_env = ENV["QUARKS_NUCLEI_PATHS"].to_s.strip
      remote_env = ENV["QUARKS_REPO_URLS"].to_s.strip

      local_paths = []
      local_paths.concat(local_env.split(":").map(&:strip)) unless local_env.empty?
      local_paths.concat([
        File.join(PROJECT_ROOT, "nuclei"),
        File.join(PROJECT_ROOT, "src", "quarks", "nuclei"),
        File.join(Env.root, "nuclei"),
        File.expand_path("~/.quarks/nuclei"),
        "/usr/share/quarks/nuclei",
        "/usr/local/share/quarks/nuclei"
      ])

      web_repos = WebRepoManager.load_repos
      remote_sources = []

      if remote_env.empty? && web_repos.any?
        remote_sources = web_repos.values.sort_by(&:priority).filter_map do |repo|
          next unless repo.enabled
          Source.new(type: :remote, location: repo.manifest_url, name: repo.name)
        end
      else
        unless remote_env.empty?
          if ENV["QUARKS_ALLOW_UNSIGNED_REPOS"] == "1"
            remote_sources = split_remote_urls(remote_env).map do |url|
              Source.new(type: :remote, location: url, name: url)
            end
          else
            @warnings&.push("QUARKS_REPO_URLS is disabled unless QUARKS_ALLOW_UNSIGNED_REPOS=1; configure a pinned web repository instead")
          end
        end
      end

      [
        *local_paths.map { |path| Source.new(type: :local, location: File.expand_path(path), name: File.basename(path)) },
        *remote_sources
      ]
    end

    def normalize_name(name_or_atom)
      value = name_or_atom.to_s.strip
      return "" if value.empty?

      slash = value.index("/")
      value = value[(slash + 1)..] if slash
      value.downcase
    end

    def find_package(name_or_atom)
      scan_all unless @scanned

      value = name_or_atom.to_s.strip
      return nil if value.empty?

      if value.include?("/")
        @cache_by_atom[value.downcase]
      else
        @cache_by_name[value.downcase]
      end
    end

    def package_source(name_or_atom)
      value = name_or_atom.to_s.strip
      return nil if value.empty?

      if value.include?("/")
        @source_by_atom[value.downcase]
      else
        @source_by_name[normalize_name(value)]
      end
    end

    def list_atoms
      scan_all unless @scanned
      @sorted_atoms ||= @cache_by_atom.keys.sort.freeze
      @sorted_atoms.dup
    end

    def blockers_for(name_or_atom)
      target = normalize_name(name_or_atom)
      return [] if target.empty?
      Array(@blockers_by_target[target]).dup
    end

    def source_overview
      @sources.map do |source|
        {
          type: source.type,
          location: source.location,
          name: source.name
        }
      end
    end

    def update(force: false)
      @cache_by_atom.clear
      @cache_by_name.clear
      @source_by_atom.clear
      @source_by_name.clear
      @blockers_by_target.clear
      @sorted_atoms = nil
      @errors.clear
      @warnings.clear
      @quarantined.clear
      @scanned = false

      sync_web_repos(force: force)
      scan_all(refresh_remote: false)
      list_atoms.length
    end

    def sync_web_repos(force: false)
      web_repos = WebRepoManager.load_repos
      return if web_repos.empty?

      results = WebRepoManager.sync_all(force: force, offline_ok: true)

      results[:errors].each do |error|
        @warnings << "Web repo sync: #{error}"
      end

      results[:results]
    end

    private

    def split_remote_urls(value)
      value.to_s.split(/(?:[\s,]+|:(?=https?:\/\/))/).map(&:strip).reject(&:empty?)
    end

    def normalize_sources(input)
      values = case input
               when Array then input
               else [input]
               end

      values.flatten.compact.map do |entry|
        case entry
        when Source
          entry
        else
          value = entry.to_s.strip
          next if value.empty?

          if value.start_with?("http://", "https://")
            Source.new(type: :remote, location: value, name: value)
          else
            Source.new(type: :local, location: File.expand_path(value), name: File.basename(value))
          end
        end
      end.compact.uniq { |source| [source.type, source.location] }
    end

    def scan_all(refresh_remote: false)
      return if @scanned && !refresh_remote

      @sources.each do |source|
        case source.type
        when :local
          scan_local_source(source)
        when :remote
          scan_remote_source(source, refresh: refresh_remote)
        else
          @errors << "Unknown repository source type: #{source.type.inspect}"
        end
      end

      @scanned = true
      raise DuplicatePackageError, @errors.join("\n") if @errors.any?
    end

    def scan_local_source(source)
      repo_path = source.location
      return unless Dir.exist?(repo_path)

      patterns = [
        File.join(repo_path, "*.nuclei"),
        File.join(repo_path, "*", "*.nuclei")
      ]

      patterns.each do |glob|
        Dir.glob(glob).sort.each do |file|
          inferred_category = infer_category(repo_path, file)

          begin
            pkg = Quarks::Package.load_from_nuclei(file)
            pkg.category = inferred_category if pkg.category.to_s.strip.empty? && inferred_category
            register_package(pkg, source_path: file)
          rescue DuplicatePackageError => e
            @errors << e.message
          rescue NucleiParseError, NucleiSchemaError => e
            msg = "Quarantined invalid recipe #{file}: #{e.message}"
            @quarantined << { source: file, error: e.message }
            @warnings << msg
            warn msg if Env.debug?
          rescue => e
            msg = "Failed to load #{file}: #{e.message}"
            @errors << msg
            warn msg if Env.debug?
          end
        end
      end
    end

    def scan_remote_source(source, refresh: false)
      manifest = load_remote_manifest(source, refresh: refresh)
      return unless manifest.is_a?(Hash)

      entries = Array(manifest["packages"] || manifest[:packages])
      entries.each_with_index do |entry, idx|
        begin
          pkg = package_from_manifest_entry(entry)
          register_package(pkg, source_path: "#{source.location}##{idx + 1}")
        rescue DuplicatePackageError => e
          @errors << e.message
        rescue NucleiSchemaError => e
          @quarantined << { source: "#{source.location}##{idx + 1}", error: e.message }
          @warnings << "Quarantined invalid remote package from #{source.location}: #{e.message}"
        rescue => e
          @errors << "Failed to load remote package from #{source.location}: #{e.message}"
        end
      end
    end

    def package_from_manifest_entry(entry)
      h = stringify_hash(entry)
      name = (h["name"] || h["package_name"]).to_s.strip
      raise "Remote package entry missing name" if name.empty?

      pkg = Quarks::Package.new(name)
      pkg.version = h.fetch("version", "0.0.0").to_s
      pkg.description = h.fetch("description", "").to_s
      pkg.homepage = h.fetch("homepage", "").to_s
      pkg.license = h.fetch("license", "Unknown").to_s
      pkg.category = h.fetch("category", "app").to_s

      pkg.dependencies = Array(h["dependencies"]).map(&:to_s)
      pkg.build_dependencies = Array(h["build_dependencies"]).map(&:to_s)
      pkg.host_tools = Array(h["host_tools"]).map(&:to_s)
      pkg.configure_flags = Array(h["configure_flags"]).map(&:to_s)
      pkg.build_commands = Array(h["build_commands"]).map(&:to_s)
      pkg.install_commands = Array(h["install_commands"]).map(&:to_s)
      pkg.patches = Array(h["patches"]).map { |p| stringify_hash(p).transform_keys(&:to_sym) }
      pkg.environment = stringify_hash(h["environment"] || {})

      pkg.build_system = h.fetch("build_system", "auto").to_s.to_sym
      pkg.build_dir = h.fetch("build_dir", "build").to_s
      pkg.install_prefix = h.fetch("install_prefix", "/usr").to_s
      pkg.make_args = Array(h["make_args"]).map(&:to_s)
      pkg.cmake_args = Array(h["cmake_args"]).map(&:to_s)
      pkg.meson_args = Array(h["meson_args"]).map(&:to_s)
      pkg.slot = h["slot"]&.to_s
      pkg.subslot = h["subslot"]&.to_s
      pkg.blocks = Array(h["blocks"]).map(&:to_s)
      pkg.blocked_by = Array(h["blocked_by"]).map(&:to_s)
      pkg.use_dependencies = Array(h["use_dependencies"]).map { |value| stringify_hash(value).transform_keys(&:to_sym) }
      pkg.provided_use = Array(h["provided_use"]).map(&:to_s)
      pkg.required_use = Array(h["required_use"]).map(&:to_s)
      pkg.iuse = Array(h["iuse"]).map(&:to_s)
      pkg.provided_by = h["provided_by"]&.to_s
      pkg.restrict = Array(h["restrict"]).map(&:to_s)

      sources = Array(h["sources"])
      if sources.empty? && h["source_url"]
        sources = [{
          "url" => h["source_url"],
          "hash" => h["source_checksum"],
          "algorithm" => h["source_algorithm"] || "sha256"
        }]
      end
      pkg.sources = []
      pkg.checksums = {}
      pkg.source_sizes = {}
      sources.each do |src|
        src_hash = stringify_hash(src)
        url = src_hash["url"].to_s.strip
        next if url.empty?

        pkg.sources << url
        hash = src_hash["hash"].to_s.strip
        algorithm = src_hash.fetch("algorithm", "sha256").to_s.strip
        pkg.checksums[url] = { hash: hash, algorithm: algorithm } unless hash.empty?
        pkg.source_sizes[url] = src_hash["size"] unless src_hash["size"].nil?
      end

      pkg.validate!(path: "(remote manifest)")
      pkg
    end

    def register_package(pkg, source_path:)
      atom = pkg.atom.to_s.downcase
      name = pkg.name.to_s.downcase
      return if atom.empty? || name.empty?

      if @cache_by_atom.key?(atom)
        prev = @source_by_atom[atom]
        handle_duplicate!("Duplicate package atom '#{atom}' defined in both #{prev} and #{source_path}")
      end

      if @cache_by_name.key?(name)
        prev = @source_by_name[name]
        handle_duplicate!("Duplicate package name '#{name}' defined in both #{prev} and #{source_path}")
      end

      @cache_by_atom[atom] = pkg
      @cache_by_name[name] = pkg
      @source_by_atom[atom] = source_path
      @source_by_name[name] = source_path
      Array(pkg.blocks).each do |blocked|
        target = normalize_name(blocked)
        next if target.empty?
        blockers = (@blockers_by_target[target] ||= [])
        blockers << atom unless blockers.include?(atom)
      end
      @sorted_atoms = nil
    end

    def handle_duplicate!(message)
      if Env.allow_duplicates?
        @warnings << message
      else
        raise DuplicatePackageError, message
      end
    end

    def infer_category(repo_path, file)
      rel = file.sub(repo_path + "/", "")
      parts = rel.split("/")
      parts.length >= 2 ? parts[0] : nil
    end

    def remote_cache_dir
      dir = File.join(Env.state_root, "var", "cache", "quarks", "repositories")
      Security.secure_directory(dir)
    end

    def load_remote_manifest(source, refresh: false)
      web_repos = WebRepoManager.load_repos

      if web_repos.key?(source.name)
        return load_from_web_repo(web_repos[source.name], refresh: refresh)
      end

      unless ENV["QUARKS_ALLOW_UNSIGNED_REPOS"] == "1"
        @errors << "Refusing unsigned remote repository #{source.location}; add it with a pinned signing key"
        return nil
      end

      cache_path = remote_cache_path(source.location)

      if refresh || !File.exist?(cache_path)
        begin
          body = fetch_url(source.location)
          Security.atomic_write(cache_path, body)
        rescue => e
          @errors << "Failed to fetch #{source.location}: #{e.message}"
          if File.exist?(cache_path)
            return JSON.parse(File.read(cache_path))
          end
          return nil
        end
      end

      JSON.parse(File.read(cache_path))
    rescue JSON::ParserError => e
      @errors << "Invalid repository manifest #{source.location}: #{e.message}"
      nil
    rescue => e
      @errors << "Failed to load manifest #{source.location}: #{e.message}"
      nil
    end

    def load_from_web_repo(repo, refresh: false)
      if refresh
        WebRepoManager.sync_repo(repo.name, force: true, offline_ok: true)
      else
        WebRepoManager.load_cached_manifest(repo.name, repo: repo)
      end
    rescue => e
      @warnings << "Web repo '#{repo.name}' fetch failed: #{e.message}"
      WebRepoManager.sync_repo(repo.name, offline_ok: true)
    end

    def infer_repo_name_from_url(url)
      uri = URI.parse(url)
      host = uri.host || "unknown"
      path = uri.path.to_s.gsub("/", "_").gsub(".json", "").strip
      path = "main" if path.empty?
      "#{host}_#{path}"
    rescue
      "unknown"
    end

    def remote_cache_path(url)
      digest = Digest::SHA256.hexdigest(url)
      File.join(remote_cache_dir, "#{digest}.json")
    end

    def fetch_url(url)
      allow_http = ENV["QUARKS_ALLOW_INSECURE_REPOS"] == "1"
      allow_private = ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
      current_uri = Security.validate_remote_uri!(
        url,
        purpose: "unsigned repository manifest",
        allow_http: allow_http,
        allow_private: allow_private,
        resolve: false
      )

      6.times do
        http = Net::HTTP.new(current_uri.host, current_uri.port, nil, nil)
        addresses = Security.network_addresses!(current_uri.host, purpose: "unsigned repository manifest", allow_private: allow_private)
        raise "Repository host did not resolve: #{current_uri.host}" if addresses.empty?
        http.ipaddr = addresses.first
        http.use_ssl = current_uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = 30
        http.write_timeout = 30 if http.respond_to?(:write_timeout=)
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
        http.max_retries = 0

        body = +"".b
        response = nil
        http.start do
          request = Net::HTTP::Get.new(current_uri)
          request["User-Agent"] = "Quarks/#{Quarks::VERSION rescue 'dev'}"
          request["Accept-Encoding"] = "identity"
          http.request(request) do |incoming|
            response = incoming
            next unless incoming.is_a?(Net::HTTPSuccess)

            declared = Integer(incoming["Content-Length"].to_s, exception: false)
            raise "Repository manifest exceeds 16 MiB" if declared && declared > 16 * 1024 * 1024
            incoming.read_body do |chunk|
              raise "Repository manifest exceeds 16 MiB" if body.bytesize + chunk.bytesize > 16 * 1024 * 1024
              body << chunk
            end
          end
        end

        return body if response.is_a?(Net::HTTPSuccess)
        unless response.is_a?(Net::HTTPRedirection)
          raise "HTTP #{response.code} #{response.message}"
        end
        location = response["location"].to_s
        raise "Repository redirect is missing a location" if location.empty?
        target = URI.join(current_uri.to_s, location)
        if current_uri.scheme == "https" && target.scheme != "https" && !allow_http
          raise "Refusing repository HTTPS downgrade redirect"
        end
        current_uri = Security.validate_remote_uri!(
          target,
          purpose: "unsigned repository redirect",
          allow_http: allow_http,
          allow_private: allow_private,
          resolve: false
        )
      end
      raise "Too many redirects while fetching repository manifest"
    end

    def stringify_hash(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      else
        {}
      end
    end
  end
end
