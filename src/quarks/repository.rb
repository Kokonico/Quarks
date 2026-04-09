# frozen_string_literal: true

require "json"
require "digest"
require "fileutils"
require "net/http"
require "uri"
require "quarks/env"
require "quarks/package"
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

    attr_reader :sources

    def initialize(custom_sources = nil)
      @sources = normalize_sources(custom_sources || default_sources)
      @cache_by_atom = {}
      @cache_by_name = {}
      @source_by_atom = {}
      @source_by_name = {}
      @errors = []
      @warnings = []
      @scanned = false
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
        File.join(Dir.pwd, "nuclei"),
        File.join(Env.root, "nuclei"),
        File.expand_path("~/.quarks/nuclei"),
        "/usr/share/quarks/nuclei",
        "/usr/local/share/quarks/nuclei"
      ])

      web_repos = WebRepoManager.load_repos
      remote_urls = []

      if remote_env.empty? && web_repos.any?
        remote_urls = web_repos.values.sort_by(&:priority).map(&:manifest_url)
      else
        remote_urls = remote_env.split(":").map(&:strip) unless remote_env.empty?
      end

      [
        *local_paths.map { |path| Source.new(type: :local, location: File.expand_path(path), name: File.basename(path)) },
        *remote_urls.reject(&:empty?).map { |url| Source.new(type: :remote, location: url, name: url) }
      ]
    end

    def normalize_name(name_or_atom)
      value = name_or_atom.to_s.strip
      return "" if value.empty?

      value = value.split("/", 2).last if value.include?("/")
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
      @cache_by_atom.keys.sort
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

    def update
      @cache_by_atom.clear
      @cache_by_name.clear
      @source_by_atom.clear
      @source_by_name.clear
      @errors.clear
      @warnings.clear
      @scanned = false

      sync_web_repos
      scan_all(refresh_remote: true)
      list_atoms.length
    end

    def sync_web_repos(force: false, verify: true)
      web_repos = WebRepoManager.load_repos
      return if web_repos.empty?

      results = WebRepoManager.sync_all(force: force, verify: verify, offline_ok: true)

      results[:errors].each do |error|
        @warnings << "Web repo sync: #{error}"
      end

      results[:results]
    end

    private

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
        rescue => e
          @errors << "Failed to load remote package from #{source.location}: #{e.message}"
        end
      end
    end

    def package_from_manifest_entry(entry)
      h = stringify_hash(entry)
      name = h["name"].to_s.strip
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

      sources = Array(h["sources"])
      pkg.sources = []
      pkg.checksums = {}
      sources.each do |src|
        src_hash = stringify_hash(src)
        url = src_hash["url"].to_s.strip
        next if url.empty?

        pkg.sources << url
        hash = src_hash["hash"].to_s.strip
        algorithm = src_hash.fetch("algorithm", "sha256").to_s.strip
        pkg.checksums[url] = { hash: hash, algorithm: algorithm } unless hash.empty?
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
      FileUtils.mkdir_p(dir)
      dir
    end

    def load_remote_manifest(source, refresh: false)
      web_repos = WebRepoManager.load_repos
      repo_name = infer_repo_name_from_url(source.location)

      if web_repos.key?(repo_name)
        return load_from_web_repo(web_repos[repo_name], refresh: refresh)
      end

      cache_path = remote_cache_path(source.location)

      if refresh || !File.exist?(cache_path)
        begin
          body = fetch_url(source.location)
          File.write(cache_path, body)
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
      manifest_data = WebRepoManager.fetch_manifest(repo, use_cache: !refresh, verify: true)
      manifest_data
    rescue => e
      @warnings << "Web repo '#{repo.name}' fetch failed: #{e.message}"
      WebRepoManager.load_cached_manifest(repo.name)
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
      uri = URI.parse(url)
      raise "Unsupported repository URL scheme: #{uri.scheme}" unless %w[http https].include?(uri.scheme)

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Quarks/#{Quarks::VERSION rescue 'dev'}"
        response = http.request(request)
        raise "HTTP #{response.code} #{response.message}" unless response.is_a?(Net::HTTPSuccess)
        response.body.to_s
      end
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
