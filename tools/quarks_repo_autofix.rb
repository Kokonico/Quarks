#!/usr/bin/env ruby
# frozen_string_literal: true

require 'json'
require 'yaml'
require 'digest'
require 'fileutils'
require 'net/http'
require 'openssl'
require 'optparse'
require 'uri'
require 'time'
require 'thread'
require 'set'

module QuarksRepoAutofix
  VERSION = '0.1.0'

  class Error < StandardError; end
  class HttpError < Error; end
  class ParseError < Error; end
  class UpdateSkipped < Error; end

  module Log
    module_function

    def info(msg)  = $stdout.puts("[INFO] #{msg}")
    def warn(msg)  = $stdout.puts("[WARN] #{msg}")
    def error(msg) = $stderr.puts("[ERR ] #{msg}")
    def ok(msg)    = $stdout.puts("[ OK ] #{msg}")
  end

  class NaturalVersion
    include Comparable

    attr_reader :raw

    def initialize(raw)
      @raw = raw.to_s.strip
    end

    def <=>(other)
      other = NaturalVersion.new(other) unless other.is_a?(NaturalVersion)
      a = tokenize(raw)
      b = tokenize(other.raw)
      max = [a.length, b.length].max
      0.upto(max - 1) do |i|
        x = a[i]
        y = b[i]
        return -1 if x.nil? && !y.nil?
        return 1 if !x.nil? && y.nil?
        cmp = compare_token(x, y)
        return cmp unless cmp.zero?
      end
      0
    end

    private

    def tokenize(str)
      str.scan(/[0-9]+|[A-Za-z]+/).map do |token|
        token.match?(/\A\d+\z/) ? token.to_i : token.downcase
      end
    end

    def compare_token(a, b)
      if a.is_a?(Integer) && b.is_a?(Integer)
        a <=> b
      elsif a.is_a?(Integer)
        1
      elsif b.is_a?(Integer)
        -1
      else
        a <=> b
      end
    end
  end

  class HttpClient
    DEFAULT_HEADERS = {
      'User-Agent' => "QuarksRepoAutofix/#{VERSION}",
      'Accept' => '*/*'
    }.freeze

    def initialize(token: nil, timeout: 20, retries: 2)
      @token = token
      @timeout = timeout
      @retries = retries
    end

    def get_json(url, headers: {})
      response = request(:get, url, headers: headers.merge('Accept' => 'application/json'))
      JSON.parse(response[:body])
    end

    def get_text(url, headers: {})
      request(:get, url, headers: headers)[:body]
    end

    def head(url, headers: {})
      request(:head, url, headers: headers)
    end

    def download(url, destination, headers: {}, max_bytes: nil)
      dest_dir = File.dirname(destination)
      FileUtils.mkdir_p(dest_dir)

      with_retries("download #{url}") do
        uri = URI(url)
        current = uri
        redirects = 0

        loop do
          http = build_http(current)
          req = Net::HTTP::Get.new(current)
          merged_headers(headers).each { |k, v| req[k] = v }

          http.request(req) do |res|
            case res
            when Net::HTTPSuccess
              bytes = 0
              File.open(destination, 'wb') do |f|
                res.read_body do |chunk|
                  bytes += chunk.bytesize
                  raise HttpError, "Refusing oversized download (#{bytes} bytes > #{max_bytes})" if max_bytes && bytes > max_bytes
                  f.write(chunk)
                end
              end
              return { status: res.code.to_i, final_url: current.to_s, headers: res.to_hash }
            when Net::HTTPRedirection
              redirects += 1
              raise HttpError, "Too many redirects for #{url}" if redirects > 8
              current = URI.join(current.to_s, res['location'])
              next
            else
              raise HttpError, "HTTP #{res.code} #{res.message} for #{current}"
            end
          end
        end
      end
    end

    def request(method, url, headers: {})
      with_retries("#{method.to_s.upcase} #{url}") do
        uri = URI(url)
        current = uri
        redirects = 0

        loop do
          http = build_http(current)
          klass = method == :head ? Net::HTTP::Head : Net::HTTP::Get
          req = klass.new(current)
          merged_headers(headers).each { |k, v| req[k] = v }
          res = http.request(req)

          case res
          when Net::HTTPSuccess
            return { status: res.code.to_i, body: res.body.to_s, headers: res.to_hash, final_url: current.to_s }
          when Net::HTTPRedirection
            redirects += 1
            raise HttpError, "Too many redirects for #{url}" if redirects > 8
            current = URI.join(current.to_s, res['location'])
          else
            raise HttpError, "HTTP #{res.code} #{res.message} for #{current}"
          end
        end
      end
    end

    private

    def merged_headers(headers)
      out = DEFAULT_HEADERS.merge(headers)
      if @token && !@token.empty?
        out['Authorization'] ||= "Bearer #{@token}"
      end
      out
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
      http.ssl_timeout = @timeout if http.respond_to?(:ssl_timeout=)
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http
    end

    def with_retries(label)
      attempt = 0
      begin
        attempt += 1
        yield
      rescue StandardError => e
        raise if attempt > (@retries + 1)
        sleep(0.5 * attempt)
        retry
      end
    end
  end

  class Cache
    def initialize(path)
      @path = path
      @mutex = Mutex.new
      @data = File.file?(@path) ? JSON.parse(File.read(@path)) : {}
    rescue JSON::ParserError
      @data = {}
    end

    def fetch(key)
      @mutex.synchronize { @data[key] }
    end

    def store(key, value)
      @mutex.synchronize { @data[key] = value }
    end

    def save!
      @mutex.synchronize do
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate(@data))
      end
    end
  end

  class PackageRecipe
    attr_reader :path, :lines, :name, :version, :category, :description,
                :homepage, :source_url, :checksum, :algorithm, :build_system,
                :source_start_idx, :source_end_idx, :checksum_idx, :algorithm_idx,
                :build_system_idx, :decl_idx

    def initialize(path)
      @path = path
      @lines = File.readlines(path, chomp: true)
      parse!
    end

    def atom
      [category, name].compact.join('/')
    end

    def to_h
      {
        path: path,
        atom: atom,
        name: name,
        version: version,
        category: category,
        homepage: homepage,
        source_url: source_url,
        checksum: checksum,
        algorithm: algorithm,
        build_system: build_system
      }
    end

    def infer_build_system
      return build_system if build_system
      content = @lines.join("\n")
      case content
      when /cmake\s+-S\b|cmake\s+\.\.|cmake\s+--build\b/i then 'cmake'
      when /\bmeson\b/i then 'meson'
      when /\.\/configure\b|autogen\.sh|autoreconf\b|bootstrap\b/i then 'autotools'
      when /\bninja\b/i then 'ninja'
      when /\bmake\b/i then 'make'
      else 'manual'
      end
    end

    def apply_update!(new_version:, new_url:, new_checksum:, new_algorithm: 'sha256', new_build_system: nil)
      updated = @lines.dup

      if decl_idx
        updated[decl_idx] = updated[decl_idx].sub(/(nuclei\s+"[^"]+"\s*,\s*")([^"]+)(")/, "\\1#{new_version}\\3")
      end

      if source_start_idx.nil?
        raise ParseError, "No source block found in #{path}"
      end

      updated[source_start_idx] = updated[source_start_idx].sub(/source\s+"[^"]+"/, "source \"#{new_url}\"")
      if updated[source_start_idx].strip.end_with?(',')
        # keep as-is
      else
        updated[source_start_idx] = updated[source_start_idx] + ','
      end

      if checksum_idx
        updated[checksum_idx] = indent_like(updated[checksum_idx], "checksum: \"#{new_checksum}\",")
      else
        updated.insert(source_start_idx + 1, source_indent + "checksum: \"#{new_checksum}\",")
        bump_indices_after_insert!(source_start_idx + 1)
      end

      if algorithm_idx
        updated[algorithm_idx] = indent_like(updated[algorithm_idx], "algorithm: \"#{new_algorithm}\"")
      else
        insert_at = checksum_idx ? checksum_idx + 1 : source_start_idx + 2
        updated.insert(insert_at, source_indent + "algorithm: \"#{new_algorithm}\"")
        bump_indices_after_insert!(insert_at)
      end

      if build_system_idx
        if new_build_system
          updated[build_system_idx] = indent_like(updated[build_system_idx], "build_system :#{new_build_system}")
        end
      elsif new_build_system
        insert_idx = insertion_point_for_build_system(updated)
        updated.insert(insert_idx, "  build_system :#{new_build_system}")
      end

      File.write(path, updated.join("\n") + "\n")
      @lines = updated
      parse!
      true
    end

    private

    def parse!
      @decl_idx = @source_start_idx = @source_end_idx = nil
      @checksum_idx = @algorithm_idx = @build_system_idx = nil
      @name = @version = @category = @description = @homepage = @source_url = @checksum = @algorithm = @build_system = nil

      @lines.each_with_index do |line, idx|
        if @decl_idx.nil? && line =~ /^\s*nuclei\s+"([^"]+)"\s*,\s*"([^"]+)"/
          @decl_idx = idx
          @name = Regexp.last_match(1)
          @version = Regexp.last_match(2)
        end

        @category ||= Regexp.last_match(1) if line =~ /^\s*category\s+"([^"]+)"/
        @description ||= Regexp.last_match(1) if line =~ /^\s*description\s+"([^"]+)"/
        @homepage ||= Regexp.last_match(1) if line =~ /^\s*homepage\s+"([^"]+)"/

        if @build_system_idx.nil? && line =~ /^\s*build_system\s+:([A-Za-z0-9_]+)/
          @build_system_idx = idx
          @build_system = Regexp.last_match(1)
        end

        next unless @source_start_idx.nil? && line =~ /^\s*source\s+"([^"]+)"/

        @source_start_idx = idx
        @source_url = Regexp.last_match(1)
        block_end = idx
        j = idx + 1
        while j < @lines.length
          break unless @lines[j] =~ /^\s{2,}(checksum:|algorithm:|sha256:|sha512:|md5:)/ || @lines[j].strip.empty?
          block_end = j if @lines[j] =~ /checksum:|algorithm:|sha256:|sha512:|md5:/
          j += 1
        end
        @source_end_idx = block_end
      end

      if @source_start_idx
        (@source_start_idx..[@source_end_idx || @source_start_idx, @lines.length - 1].min).each do |idx|
          line = @lines[idx]
          if line =~ /checksum:\s*"([^"]+)"/
            @checksum_idx = idx
            @checksum = Regexp.last_match(1)
          elsif line =~ /sha256:\s*"([^"]+)"/
            @checksum_idx = idx
            @checksum = Regexp.last_match(1)
            @algorithm = 'sha256'
          elsif line =~ /sha512:\s*"([^"]+)"/
            @checksum_idx = idx
            @checksum = Regexp.last_match(1)
            @algorithm = 'sha512'
          elsif line =~ /md5:\s*"([^"]+)"/
            @checksum_idx = idx
            @checksum = Regexp.last_match(1)
            @algorithm = 'md5'
          end

          if line =~ /algorithm:\s*"([^"]+)"/
            @algorithm_idx = idx
            @algorithm = Regexp.last_match(1)
          end
        end
      end
    end

    def source_indent
      start_line = @lines[@source_start_idx]
      whitespace = start_line[/^\s*/]
      whitespace + '       '
    end

    def indent_like(line, replacement)
      indent = line[/^\s*/]
      indent + replacement
    end

    def bump_indices_after_insert!(idx)
      @checksum_idx += 1 if @checksum_idx && @checksum_idx >= idx
      @algorithm_idx += 1 if @algorithm_idx && @algorithm_idx >= idx
      @build_system_idx += 1 if @build_system_idx && @build_system_idx >= idx
      @source_end_idx += 1 if @source_end_idx && @source_end_idx >= idx
    end

    def insertion_point_for_build_system(lines)
      install_prefix_idx = lines.index { |line| line =~ /^\s*install_prefix\b/ }
      return install_prefix_idx + 1 if install_prefix_idx
      return (@source_end_idx || @source_start_idx) + 1 if @source_start_idx
      (@decl_idx || 0) + 1
    end
  end

  class Candidate
    attr_reader :version, :source_url, :checksum, :provider, :notes

    def initialize(version:, source_url:, checksum:, provider:, notes: nil)
      @version = version.to_s
      @source_url = source_url.to_s
      @checksum = checksum.to_s.downcase
      @provider = provider.to_s
      @notes = notes
    end

    def to_h
      { version: version, source_url: source_url, checksum: checksum, provider: provider, notes: notes }
    end
  end

  class Overrides
    def initialize(path)
      @data = File.file?(path) ? YAML.safe_load(File.read(path), permitted_classes: [Date, Time], aliases: true) : {}
      @data ||= {}
    rescue Psych::SyntaxError => e
      raise Error, "Invalid overrides file #{path}: #{e.message}"
    end

    def package(name)
      (@data['packages'] || {})[name.to_s] || {}
    end
  end

  class SourceAdapter
    def initialize(http:, cache:, overrides:)
      @http = http
      @cache = cache
      @overrides = overrides
    end

    def match?(_recipe)
      false
    end

    def latest(_recipe)
      raise NotImplementedError
    end

    protected

    attr_reader :http, :cache, :overrides

    def cache_fetch(key)
      cached = cache.fetch(key)
      return cached if cached
      value = yield
      cache.store(key, value)
      value
    end

    def normalize_sha256(value)
      digest = value.to_s.sub(/\Asha256:/, '').strip.downcase
      raise UpdateSkipped, 'Missing usable sha256 digest' unless digest.match?(/\A[0-9a-f]{64}\z/)
      digest
    end
  end

  class GitHubAdapter < SourceAdapter
    def match?(recipe)
      !github_repo(recipe).nil?
    end

    def latest(recipe)
      owner, repo = github_repo(recipe)
      raise UpdateSkipped, 'No GitHub repository inferred' unless owner && repo

      release = fetch_latest_release(owner, repo)
      if release
        candidate_from_release(recipe, owner, repo, release)
      else
        tag = fetch_latest_tag(owner, repo)
        raise UpdateSkipped, 'No GitHub release or tag found' unless tag
        candidate_from_tag(recipe, owner, repo, tag)
      end
    end

    private

    def github_repo(recipe)
      explicit = overrides.package(recipe.name)['github_repo']
      return explicit.split('/', 2) if explicit.to_s.include?('/')

      url = recipe.source_url.to_s
      patterns = [
        %r{github\.com/([^/]+)/([^/]+)/archive/},
        %r{github\.com/([^/]+)/([^/]+)/releases/download/},
        %r{codeload\.github\.com/([^/]+)/([^/]+)/tar\.gz/}
      ]
      patterns.each do |rx|
        if url =~ rx
          return [Regexp.last_match(1), Regexp.last_match(2)]
        end
      end
      nil
    end

    def fetch_latest_release(owner, repo)
      cache_fetch("github-release:#{owner}/#{repo}") do
        begin
          http.get_json("https://api.github.com/repos/#{owner}/#{repo}/releases/latest", headers: github_headers)
        rescue StandardError
          nil
        end
      end
    end

    def fetch_latest_tag(owner, repo)
      cache_fetch("github-tags:#{owner}/#{repo}") do
        begin
          tags = http.get_json("https://api.github.com/repos/#{owner}/#{repo}/tags?per_page=100", headers: github_headers)
          best = Array(tags).map { |t| t['name'] }.compact.max_by { |name| NaturalVersion.new(name.gsub(/^v/, '')) }
          { 'name' => best } if best
        rescue StandardError
          nil
        end
      end
    end

    def candidate_from_release(recipe, owner, repo, release)
      tag = release['tag_name'].to_s
      version = tag.gsub(/^v/, '')
      asset = choose_asset(recipe, release)
      if asset
        checksum = if asset['digest'].to_s.start_with?('sha256:')
                     normalize_sha256(asset['digest'])
                   else
                     fetch_sha256(asset['browser_download_url'])
                   end
        return Candidate.new(version: version,
                             source_url: asset['browser_download_url'],
                             checksum: checksum,
                             provider: 'github-release-asset',
                             notes: "tag=#{tag}")
      end

      url = "https://github.com/#{owner}/#{repo}/archive/refs/tags/#{tag}.tar.gz"
      checksum = fetch_sha256(url)
      Candidate.new(version: version, source_url: url, checksum: checksum, provider: 'github-release-archive', notes: "tag=#{tag}")
    end

    def candidate_from_tag(recipe, owner, repo, tag_payload)
      tag = tag_payload['name'].to_s
      version = tag.gsub(/^v/, '')
      url = "https://github.com/#{owner}/#{repo}/archive/refs/tags/#{tag}.tar.gz"
      checksum = fetch_sha256(url)
      Candidate.new(version: version, source_url: url, checksum: checksum, provider: 'github-tag-archive', notes: "tag=#{tag}")
    end

    def choose_asset(recipe, release)
      assets = Array(release['assets'])
      return nil if assets.empty?
      current_basename = File.basename(URI(recipe.source_url).path) rescue File.basename(recipe.source_url.to_s)
      sanitized_current = current_basename.gsub(recipe.version.to_s, '__VERSION__')
      version = release['tag_name'].to_s.gsub(/^v/, '')
      target_names = [
        current_basename.gsub(recipe.version.to_s, version),
        sanitized_current.gsub('__VERSION__', version),
        current_basename
      ].uniq
      assets.find { |asset| target_names.include?(asset['name']) } || assets.find { |asset| asset['name'].to_s.end_with?('.tar.gz', '.tar.xz', '.tar.bz2', '.tgz', '.zip') }
    end

    def github_headers
      {
        'Accept' => 'application/vnd.github+json',
        'X-GitHub-Api-Version' => '2022-11-28'
      }
    end

    def fetch_sha256(url)
      temp = TempPaths.download_path(url)
      http.download(url, temp, max_bytes: 512 * 1024 * 1024)
      Digest::SHA256.file(temp).hexdigest.downcase
    ensure
      FileUtils.rm_f(temp) if temp && File.exist?(temp)
    end
  end

  class PyPIAdapter < SourceAdapter
    def match?(recipe)
      override = overrides.package(recipe.name)
      return true if override['pypi_name']
      recipe.source_url.to_s.include?('pypi') || recipe.homepage.to_s.include?('pypi.org/project')
    end

    def latest(recipe)
      project = overrides.package(recipe.name)['pypi_name'] || infer_project(recipe)
      raise UpdateSkipped, 'No PyPI project inferred' unless project && !project.empty?

      data = cache_fetch("pypi:#{project}") do
        http.get_json("https://pypi.org/pypi/#{project}/json")
      end

      version = data.dig('info', 'version').to_s
      raise UpdateSkipped, 'PyPI returned no latest version' if version.empty?

      files = Array(data.dig('releases', version))
      sdist = files.find { |f| f['packagetype'] == 'sdist' } || files.first
      raise UpdateSkipped, "PyPI release #{version} has no files" unless sdist

      checksum = sdist.dig('digests', 'sha256').to_s
      url = sdist['url'].to_s
      raise UpdateSkipped, 'PyPI release missing URL or sha256' if url.empty? || checksum.empty?

      Candidate.new(version: version, source_url: url, checksum: normalize_sha256(checksum), provider: 'pypi-json')
    end

    private

    def infer_project(recipe)
      return Regexp.last_match(1) if recipe.homepage.to_s =~ %r{pypi\.org/project/([^/]+)/?}
      recipe.name
    end
  end

  class GnuAdapter < SourceAdapter
    def match?(recipe)
      recipe.source_url.to_s.include?('ftp.gnu.org/gnu/') || recipe.source_url.to_s.include?('/gnu/')
    end

    def latest(recipe)
      dir_url, pkg_prefix, ext = infer_dir_and_pattern(recipe)
      html = cache_fetch("gnu-dir:#{dir_url}") { http.get_text(dir_url) }
      links = html.scan(/href=["']([^"']+)["']/i).flatten
      candidates = links.map { |href| File.basename(href) }.select { |name| name.start_with?("#{pkg_prefix}-") && name.end_with?(ext) }
      raise UpdateSkipped, "No GNU tarballs found for #{recipe.name}" if candidates.empty?

      best_name = candidates.max_by { |n| NaturalVersion.new(extract_version_from_filename(pkg_prefix, n, ext)) }
      version = extract_version_from_filename(pkg_prefix, best_name, ext)
      url = URI.join(dir_url, best_name).to_s
      checksum = fetch_sha256(url)
      Candidate.new(version: version, source_url: url, checksum: checksum, provider: 'gnu-directory-listing')
    end

    private

    def infer_dir_and_pattern(recipe)
      uri = URI(recipe.source_url)
      file = File.basename(uri.path)
      dir = recipe.source_url.sub(/[^\/]+\z/, '')
      prefix, version, ext = file.match(/\A(.+)-([^\-\/]+?)((?:\.tar\.(?:gz|xz|bz2)|\.tgz|\.zip))\z/).captures
      [dir, prefix, ext]
    rescue StandardError
      raise UpdateSkipped, "Unable to infer GNU listing pattern from #{recipe.source_url}"
    end

    def extract_version_from_filename(prefix, filename, ext)
      filename.sub(/\A#{Regexp.escape(prefix)}-/, '').sub(/#{Regexp.escape(ext)}\z/, '')
    end

    def fetch_sha256(url)
      temp = TempPaths.download_path(url)
      http.download(url, temp, max_bytes: 512 * 1024 * 1024)
      Digest::SHA256.file(temp).hexdigest.downcase
    ensure
      FileUtils.rm_f(temp) if temp && File.exist?(temp)
    end
  end

  class GenericListingAdapter < SourceAdapter
    def match?(recipe)
      recipe.source_url.to_s =~ %r{\Ahttps?://}
    end

    def latest(recipe)
      override = overrides.package(recipe.name)
      base_url = override['listing_url'] || derive_listing_url(recipe)
      pattern = Regexp.new(override['filename_regex'] || default_filename_regex(recipe))
      html = cache_fetch("listing:#{base_url}") { http.get_text(base_url) }
      links = html.scan(/href=["']([^"']+)["']/i).flatten.map { |href| File.basename(href) }
      matches = links.select { |name| name.match?(pattern) }
      raise UpdateSkipped, "No listing matches for #{recipe.name} at #{base_url}" if matches.empty?

      best_name = matches.max_by { |name| NaturalVersion.new(extract_version(name, pattern)) }
      version = extract_version(best_name, pattern)
      url = URI.join(base_url, best_name).to_s
      checksum = fetch_sha256(url)
      Candidate.new(version: version, source_url: url, checksum: checksum, provider: 'generic-listing', notes: base_url)
    end

    private

    def derive_listing_url(recipe)
      recipe.source_url.to_s.sub(/[^\/]+\z/, '')
    end

    def default_filename_regex(recipe)
      basename = File.basename(URI(recipe.source_url).path)
      escaped = Regexp.escape(basename)
      escaped = escaped.sub(Regexp.escape(recipe.version), '([0-9A-Za-z._+-]+)')
      "\\A#{escaped}\\z"
    end

    def extract_version(filename, pattern)
      match = filename.match(pattern)
      raise UpdateSkipped, "Could not extract version from #{filename}" unless match
      version = match.captures.compact.first
      raise UpdateSkipped, "No capture group for version extraction in #{pattern.inspect}" unless version
      version
    end

    def fetch_sha256(url)
      temp = TempPaths.download_path(url)
      http.download(url, temp, max_bytes: 512 * 1024 * 1024)
      Digest::SHA256.file(temp).hexdigest.downcase
    ensure
      FileUtils.rm_f(temp) if temp && File.exist?(temp)
    end
  end

  module TempPaths
    module_function

    def download_path(url)
      root = File.join(Dir.pwd, '.quarks_repo_autofix_tmp')
      FileUtils.mkdir_p(root)
      slug = Digest::SHA256.hexdigest(url)[0, 16]
      File.join(root, "#{slug}-#{File.basename(URI(url).path)}")
    end
  end

  class Planner
    def initialize(http:, cache:, overrides:)
      @adapters = [
        PyPIAdapter.new(http: http, cache: cache, overrides: overrides),
        GitHubAdapter.new(http: http, cache: cache, overrides: overrides),
        GnuAdapter.new(http: http, cache: cache, overrides: overrides),
        GenericListingAdapter.new(http: http, cache: cache, overrides: overrides)
      ]
    end

    def candidate_for(recipe)
      adapter = @adapters.find { |a| a.match?(recipe) }
      raise UpdateSkipped, 'No adapter matched' unless adapter
      adapter.latest(recipe)
    end
  end

  class Runner
    DEFAULTS = {
      repo: Dir.pwd,
      dry_run: true,
      apply: false,
      workers: 4,
      include_patterns: [],
      report: nil,
      overrides: nil,
      fix_build_systems: true,
      packages_only: []
    }.freeze

    def initialize(argv)
      @options = DEFAULTS.dup
      parse_options!(argv)
      @repo_root = File.expand_path(@options[:repo])
      @cache = Cache.new(File.join(@repo_root, '.quarks_repo_autofix', 'cache.json'))
      @overrides = Overrides.new(@options[:overrides] || File.join(@repo_root, 'quarks_repo_autofix.yml'))
      @http = HttpClient.new(token: ENV['GITHUB_TOKEN'])
      @planner = Planner.new(http: @http, cache: @cache, overrides: @overrides)
      @results = Queue.new
    end

    def run!
      recipes = discover_recipes
      Log.info("Scanning #{recipes.length} package recipe(s) under #{@repo_root}")
      queue = Queue.new
      recipes.each { |recipe_path| queue << recipe_path }
      workers = Array.new(@options[:workers]) do
        Thread.new do
          until queue.empty?
            path = queue.pop(true) rescue nil
            next unless path
            process_one(path)
            puts "Processed #{path} (#{queue.size} remaining)"
          end
        end
      end
      workers.each(&:join)
      @cache.save!
      results = []
      results << @results.pop until @results.empty?
      results.sort_by! { |r| [severity_order(r[:status]), r[:path]] }
      emit_report(results)
      results
    end

    private

    def parse_options!(argv)
      OptionParser.new do |opts|
        opts.banner = 'Usage: quarks_repo_autofix.rb [options]'

        opts.on('--repo PATH', 'Path to Quarks repo root') { |v| @options[:repo] = v }
        opts.on('--apply', 'Write changes to package recipes') do
          @options[:apply] = true
          @options[:dry_run] = false
        end
        opts.on('--dry-run', 'Only report; do not change files') do
          @options[:dry_run] = true
          @options[:apply] = false
        end
        opts.on('--workers N', Integer, 'Number of worker threads (default: 4)') { |v| @options[:workers] = [v, 1].max }
        opts.on('--package NAME', 'Only process one package name (repeatable)') { |v| @options[:packages_only] << v }
        opts.on('--report FILE', 'Write JSON report to file') { |v| @options[:report] = v }
        opts.on('--overrides FILE', 'YAML overrides file path') { |v| @options[:overrides] = v }
        opts.on('--[no-]fix-build-systems', 'Infer and add build_system when missing') { |v| @options[:fix_build_systems] = v }
        opts.on('-h', '--help', 'Show help') do
          puts opts
          exit 0
        end
      end.parse!(argv)
    end

    def discover_recipes
      patterns = [File.join(@repo_root, 'nuclei', '**', '*.nuclei'), File.join(@repo_root, 'packages', '**', 'package.nuclei')]
      files = patterns.flat_map { |p| Dir.glob(p) }.uniq.sort
      if @options[:packages_only].any?
        wanted = @options[:packages_only].to_set
        files.select do |path|
          begin
            recipe = PackageRecipe.new(path)
            wanted.include?(recipe.name) || wanted.include?(recipe.atom)
          rescue StandardError
            false
          end
        end
      else
        files
      end
    end

    def process_one(path)
      recipe = PackageRecipe.new(path)
      result = {
        path: rel(path),
        atom: recipe.atom,
        current_version: recipe.version,
        status: 'unchanged',
        actions: []
      }

      begin
        candidate = @planner.candidate_for(recipe)
        result[:candidate] = candidate.to_h

        if recipe.checksum.to_s !~ /\A[0-9a-fA-F]{64}\z/
          result[:actions] << 'fix_checksum'
        end

        if NaturalVersion.new(candidate.version) > NaturalVersion.new(recipe.version)
          result[:actions] << 'bump_version'
        end

        if recipe.source_url != candidate.source_url
          result[:actions] << 'update_source_url'
        end

        inferred_build_system = @options[:fix_build_systems] ? recipe.infer_build_system : nil
        if @options[:fix_build_systems] && recipe.build_system.nil?
          result[:actions] << "set_build_system:#{inferred_build_system}"
        end

        if result[:actions].empty?
          result[:status] = 'ok'
          result[:message] = 'Already up to date'
        else
          if @options[:apply]
            recipe.apply_update!(
              new_version: (NaturalVersion.new(candidate.version) > NaturalVersion.new(recipe.version) ? candidate.version : recipe.version),
              new_url: candidate.source_url,
              new_checksum: candidate.checksum,
              new_algorithm: 'sha256',
              new_build_system: (recipe.build_system.nil? ? inferred_build_system : nil)
            )
            result[:status] = 'updated'
            result[:message] = 'Recipe updated'
          else
            result[:status] = 'would_update'
            result[:message] = 'Dry run only'
          end
        end
      rescue UpdateSkipped => e
        result[:status] = 'skipped'
        result[:message] = e.message
      rescue StandardError => e
        result[:status] = 'error'
        result[:message] = "#{e.class}: #{e.message}"
      end

      @results << result
    end

    def emit_report(results)
      counts = results.group_by { |r| r[:status] }.transform_values(&:size)
      Log.info("Summary: updated=#{counts['updated'].to_i} would_update=#{counts['would_update'].to_i} ok=#{counts['ok'].to_i} skipped=#{counts['skipped'].to_i} error=#{counts['error'].to_i}")
      results.each do |row|
        case row[:status]
        when 'updated'      then Log.ok("#{row[:path]} -> #{row[:candidate][:version]} (#{row[:actions].join(', ')})")
        when 'would_update' then Log.warn("#{row[:path]} -> #{row[:candidate][:version]} (#{row[:actions].join(', ')})")
        when 'ok'           then Log.info("#{row[:path]} up to date")
        when 'skipped'      then Log.warn("#{row[:path]} skipped: #{row[:message]}")
        when 'error'        then Log.error("#{row[:path]} failed: #{row[:message]}")
        end
      end

      return unless @options[:report]
      payload = {
        generated_at: Time.now.utc.iso8601,
        repo: @repo_root,
        results: results
      }
      FileUtils.mkdir_p(File.dirname(@options[:report]))
      File.write(@options[:report], JSON.pretty_generate(payload))
      Log.ok("Wrote report #{@options[:report]}")
    end

    def rel(path)
      path.sub(@repo_root + '/', '')
    end

    def severity_order(status)
      {
        'error' => 0,
        'updated' => 1,
        'would_update' => 2,
        'skipped' => 3,
        'ok' => 4,
        'unchanged' => 5
      }.fetch(status, 99)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  QuarksRepoAutofix::Runner.new(ARGV).run!
end
