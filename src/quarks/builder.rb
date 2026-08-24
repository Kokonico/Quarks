# frozen_string_literal: true

require "fileutils"
require "open3"
require "net/http"
require "uri"
require "openssl"
require "digest"
require "find"
require "pathname"
require "securerandom"
require "shellwords"
require "time"

require "quarks/env"
require "quarks/hash_verifier"
require "quarks/operation_lock"
require "quarks/sandbox_build"
require "quarks/security"
require "quarks/source_size"

module Quarks
  class Builder
    MAX_SOURCE_BYTES = [Integer(ENV.fetch("QUARKS_MAX_SOURCE_BYTES", 4 * 1024 * 1024 * 1024), exception: false).to_i, 1].max.freeze
    MAX_EXTRACTED_BYTES = [Integer(ENV.fetch("QUARKS_MAX_EXTRACTED_BYTES", 20 * 1024 * 1024 * 1024), exception: false).to_i, 1].max.freeze
    MAX_EXTRACTED_FILES = [Integer(ENV.fetch("QUARKS_MAX_EXTRACTED_FILES", 250_000), exception: false).to_i, 1].max.freeze
    MAX_ARCHIVE_LIST_BYTES = 64 * 1024 * 1024
    MAX_OUTPUT_LINE_BYTES = 64 * 1024
    MAX_LOG_BYTES = [Integer(ENV.fetch("QUARKS_MAX_LOG_BYTES", 64 * 1024 * 1024), exception: false).to_i, 1].max.freeze
    class RetryableDownloadError < StandardError; end

    BuildPlan = Struct.new(
      :system, :cwd, :build_dir, :configure_cmds, :build_cmds, :install_cmds,
      keyword_init: true
    )

    attr_reader :package

    def initialize(package, current = 1, total = 1, options = {})
      @package = package
      @current = current
      @total   = total
      @options = options || {}

      @quiet   = ENV["QUARKS_QUIET"].to_s == "1" || @options[:quiet]
      @verbose = !@quiet
      @debug   = ENV["QUARKS_DEBUG"].to_s == "1" || @options[:debug]
      requested_jobs = @options[:jobs].to_i
      requested_jobs = Quarks::Env.jobs unless requested_jobs.positive?
      @jobs = [[requested_jobs, 1].max, 1024].min
      @use_flags = if @options.key?(:use_flags)
                     Array(@options[:use_flags]).map(&:to_s)
                   else
                     require "quarks/use_slots"
                     Quarks::USEConfig.new.flags_for_package(@package)
                   end

      tmp_root   = Quarks::Env.tmpdir rescue (ENV["QUARKS_TMPDIR"] || "/var/tmp/quarks")
      build_root = File.join(tmp_root, "quarks-build")
      dest_root  = File.join(tmp_root, "quarks-dest")

      slug = safe_slug(@package.full_name)
      run_id = @options[:workspace_id].to_s.strip
      run_id = "#{Process.pid}-#{SecureRandom.hex(6)}" if run_id.empty?
      workspace_slug = "#{slug}-#{safe_slug(run_id)}"

      @build_dir = File.join(build_root, workspace_slug)
      @dest_dir  = File.join(dest_root, workspace_slug)

      state_root = Quarks::Env.state_root rescue (ENV["QUARKS_STATE_ROOT"] || File.expand_path("~/.local/state/quarks"))
      @cache_dir = File.join(state_root, "var", "cache", "quarks", "distfiles")
      @log_dir   = File.join(state_root, "var", "log", "quarks")
      @log_file  = File.join(@log_dir, "#{workspace_slug}.log")
      @log_bytes = File.file?(@log_file) ? File.size(@log_file) : 0
      @log_truncated = @log_bytes >= MAX_LOG_BYTES
      @log_io = nil
      @command_cache = {}
      @source_size_tracker = @options[:source_size_tracker]

      @source_dir = nil
      @downloaded_sources = []
    end

    def fetch_only
      OperationLock.synchronize("build:#{@package.atom}:#{@package.version}") do
        fetch_only_unlocked
      end
    end

    def build
      OperationLock.synchronize("build:#{@package.atom}:#{@package.version}") do
        build_unlocked
      end
    end

    def cleanup!
      return false if @options[:keep_temp]

      FileUtils.rm_rf(@build_dir)
      FileUtils.rm_rf(@dest_dir)
      true
    end

    private

    def fetch_only_unlocked
      prepare_directories
      @downloaded_sources = download_sources
      true
    ensure
      close_log!
      cleanup!
    end

    def build_unlocked
      if Process.euid.zero? && ENV["QUARKS_ALLOW_ROOT_BUILD"] != "1"
        raise "Refusing to execute package builds as root. Run Quarks as an unprivileged user; only the final merge may elevate."
      end

      if SandboxManager.enabled?
        SandboxManager.assert_operational!(network: ENV["QUARKS_BUILD_NETWORK"] == "1")
      end

      prepare_directories
      ensure_host_tools!
      @downloaded_sources = download_sources
      stage_sources
      @source_dir = detect_source_dir!
      apply_patches
      plan = create_build_plan
      log_header("BEGIN BUILD #{@package.atom}-#{@package.version}")

      say_phase("Preparing build plan", :info)
      say_detail("Package: #{@package.atom}-#{@package.version}")
      say_detail("Build system: #{plan.system}")
      say_detail("Source dir: #{@source_dir}")
      say_detail("Build dir: #{plan.build_dir || @source_dir}")
      say_detail("Dest dir: #{@dest_dir}")
      say_detail("Jobs: #{@jobs}")

      run_commands(plan.configure_cmds, cwd: plan.cwd, env: build_env(plan), phase: "configure")
      run_commands(plan.build_cmds,     cwd: plan.cwd, env: build_env(plan), phase: "build")
      run_commands(plan.install_cmds,   cwd: plan.cwd, env: build_env(plan), phase: "install")

      finalize_destdir!
      log_header("END BUILD #{@package.atom}-#{@package.version}")
      @dest_dir
    rescue => e
      log_line("")
      log_line("BUILD FAILED: #{e.class}: #{e.message}")
      log_line(Array(e.backtrace).join("\n")) if @debug
      wrapped = build_error_with_log(e)
      cleanup!
      raise wrapped
    ensure
      close_log!
    end

    def prepare_directories
      Security.secure_directory(@cache_dir)
      Security.secure_directory(@log_dir)

      unless @options[:resume]
        FileUtils.rm_rf(@build_dir)
        FileUtils.rm_rf(@dest_dir)
      end

      FileUtils.mkdir_p(@build_dir)
      FileUtils.mkdir_p(@dest_dir)
      log_header("SESSION #{@package.atom}-#{@package.version}")
    end

    def ensure_host_tools!
      Array(@package.host_tools).each { |tool| ensure_command!(tool) }
    end

    def download_sources
      return [] if Array(@package.sources).empty?

      say_phase("Fetching sources", :info)
      @package.sources.each_with_index.map do |source, index|
        fetch_source(source.to_s, index)
      end
    end

    def fetch_source(source, index)
      local_path = resolve_local_source(source)
      uri = URI.parse(source)
      cached_path = File.join(@cache_dir, cache_filename_for(uri, index))

      if local_path
        say_detail("Using local source #{File.basename(local_path)}")
        return cached_path if File.file?(cached_path) && !File.symlink?(cached_path) && cached_source_valid?(cached_path, source)

        tmp = "#{cached_path}.part-#{Process.pid}-#{SecureRandom.hex(6)}"
        begin
          FileUtils.copy_file(local_path, tmp)
          File.chmod(0o600, tmp)
          verify_source!(tmp, source)
          File.rename(tmp, cached_path)
          source_size_tracker.record_verified(@package, source, File.size(cached_path), path: cached_path)
        ensure
          FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
        end
        return cached_path
      end

      filename = File.basename(cached_path)
      if File.file?(cached_path) && !File.symlink?(cached_path) && cached_source_valid?(cached_path, source)
        say_detail("Using cached source #{filename}")
        return cached_path
      end

      FileUtils.rm_f(cached_path) if File.exist?(cached_path) || File.symlink?(cached_path)
      say_detail("Downloading #{source}")
      download_http(uri, cached_path, source_key: source)
      cached_path
    rescue URI::InvalidURIError
      raise "Invalid source URL/path: #{source}"
    end

    def resolve_local_source(source)
      if source.start_with?("file://")
        path = URI.parse(source).path
        return File.expand_path(path) if File.file?(path)
        return nil
      end

      return File.expand_path(source) if File.file?(source)
      nil
    rescue URI::InvalidURIError, ArgumentError
      nil
    end

    def cache_filename_for(uri, index)
      Quarks::SourceSize.cache_filename(uri, index)
    end

    def cached_source_valid?(path, source)
      return false if File.symlink?(path)
      verify_source!(path, source)
      source_size_tracker.record_verified(@package, source, File.size(path), path: path)
      true
    rescue
      FileUtils.rm_f(path) rescue nil
      false
    end

    def verify_source!(path, source_key)
      checksum = lookup_checksum(source_key)
      raise "Missing checksum for package source #{source_key}" unless checksum

      declared_size = @package.source_sizes[source_key] || @package.source_sizes[source_key.to_s]
      if declared_size && File.size(path) != declared_size.to_i
        raise "Source size mismatch for #{File.basename(path)}: expected #{declared_size} bytes, got #{File.size(path)}"
      end

      expected_hash = checksum[:hash].to_s.strip
      algorithm = checksum[:algorithm].to_s.strip
      algorithm = "sha256" if algorithm.empty?

      raise "Checksum is empty for #{source_key}" if expected_hash.empty?

      ok = Quarks::HashVerifier.verify_file(
        path,
        algorithm: algorithm,
        expected_hex: expected_hash
      )

      raise "Checksum verification failed for #{File.basename(path)}" unless ok
      say_detail("Verified #{File.basename(path)} (#{algorithm})")
      true
    rescue Quarks::HashVerifier::VerificationError => e
      raise "Checksum verification failed for #{File.basename(path)}: #{e.message}"
    end

    def source_size_tracker
      @source_size_tracker ||= Quarks::SourceSize.new
    end

    def lookup_checksum(source_key)
      checksums = @package.checksums || {}
      raw = checksums[source_key] || checksums[source_key.to_s]
      return nil unless raw

      if raw.is_a?(Hash)
        {
          hash: raw[:hash] || raw["hash"],
          algorithm: raw[:algorithm] || raw["algorithm"] || "sha256"
        }
      end
    end

    def download_http(uri, dest, source_key:)
      attempts = 0
      begin
        attempts += 1
        download_http_once(uri, dest, source_key: source_key)
      rescue RetryableDownloadError, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::ECONNREFUSED => e
        retry if attempts < 3
        raise "Download failed after #{attempts} attempts: #{e.message}"
      end
    end

    def download_http_once(uri, dest, source_key:)
      allow_http = ENV["QUARKS_ALLOW_INSECURE_SOURCES"] == "1"
      allow_private = ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
      current_uri = Security.validate_remote_uri!(
        uri,
        purpose: "package source",
        allow_http: allow_http,
        allow_private: allow_private,
        resolve: false
      )

      6.times do
        addresses = Security.network_addresses!(
          current_uri.host,
          purpose: "package source",
          allow_private: allow_private
        )
        result = nil
        last_error = nil

        addresses.each do |address|
          begin
            result = download_from_address(current_uri, address, dest, source_key: source_key)
            break
          rescue RetryableDownloadError, Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, Errno::ECONNRESET, Errno::ETIMEDOUT, Errno::ECONNREFUSED, OpenSSL::SSL::SSLError, IOError => e
            last_error = e
          end
        end

        raise(last_error || "Could not connect to #{current_uri.host}") unless result
        return dest if result[:completed]

        redirect = result[:redirect]
        raise "Unexpected response while fetching #{current_uri}" unless redirect
        if current_uri.scheme == "https" && redirect.scheme != "https" && !allow_http
          raise "Refusing HTTPS downgrade redirect to #{redirect}"
        end
        current_uri = Security.validate_remote_uri!(
          redirect,
          purpose: "package source redirect",
          allow_http: allow_http,
          allow_private: allow_private,
          resolve: false
        )
      end

      raise "Too many redirects while fetching #{uri}"
    end

    def download_from_address(uri, address, dest, source_key:)
      tmp = "#{dest}.part-#{Process.pid}-#{SecureRandom.hex(6)}"
      http = Net::HTTP.new(uri.host, uri.port, nil, nil)
      http.ipaddr = address
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = 15
      http.read_timeout = 180
      http.ssl_timeout = 15
      http.max_retries = 0

      result = {}
      http.start do
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = "Quarks/#{Quarks::VERSION rescue 'dev'}"
        request["Accept-Encoding"] = "identity"
        http.request(request) do |response|
          case response
          when Net::HTTPSuccess
            declared_size = Integer(response["Content-Length"].to_s, exception: false)
            if declared_size&.positive? && declared_size > MAX_SOURCE_BYTES
              raise "Source exceeds maximum download size (#{declared_size} > #{MAX_SOURCE_BYTES})"
            end

            bytes = 0
            File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
              response.read_body do |chunk|
                bytes += chunk.bytesize
                raise "Source exceeds maximum download size (#{MAX_SOURCE_BYTES} bytes)" if bytes > MAX_SOURCE_BYTES
                file.write(chunk)
              end
              file.flush
              file.fsync
            end
            if declared_size&.positive? && bytes != declared_size
              raise RetryableDownloadError, "Incomplete response (expected #{declared_size} bytes, received #{bytes})"
            end
            verify_source!(tmp, source_key)
            File.rename(tmp, dest)
            source_size_tracker.record_verified(@package, source_key, bytes, path: dest)
            result[:completed] = true
          when Net::HTTPRedirection
            location = response["location"].to_s
            raise "Redirect missing location for #{uri}" if location.empty?
            result[:redirect] = URI.join(uri.to_s, location)
          else
            code = response.code.to_i
            message = "HTTP #{response.code} #{response.message}"
            if code == 408 || code == 425 || code == 429 || code.between?(500, 599)
              raise RetryableDownloadError, message
            end
            raise "Download failed: #{message}"
          end
        end
      end
      result
    ensure
      FileUtils.rm_f(tmp) if defined?(tmp) && tmp && File.exist?(tmp)
    end

    def stage_sources
      say_phase("Staging sources", :info)
      @downloaded_sources.each do |path|
        if archive_file?(path)
          say_detail("Extracting #{File.basename(path)}")
          extract_archive(path, @build_dir)
        else
          say_detail("Copying #{File.basename(path)} into build tree")
          copy_into_build_dir(path)
        end
      end
    end

    def archive_file?(path)
      name = File.basename(path)
      !!(name =~ /\.(tar|tar\.gz|tgz|tar\.bz2|tbz2|tar\.xz|txz|tar\.zst|zip)$/i)
    end

    def extract_archive(path, dest)
      FileUtils.mkdir_p(dest)
      validate_archive_entries!(path)

      if path =~ /\.zip$/i
        ensure_command!("unzip")
        run_shell!(
          "unzip -q #{shell_escape(path)} -d #{shell_escape(dest)}",
          cwd: dest,
          env: {},
          writable_paths: [@build_dir]
        )
      else
        ensure_command!("tar")
        run_shell!(
          "tar -xf #{shell_escape(path)} -C #{shell_escape(dest)}",
          cwd: dest,
          env: {},
          writable_paths: [@build_dir]
        )
      end
      validate_extracted_tree!(dest)
    end

    def validate_archive_entries!(path)
      tool = path.match?(/\.zip$/i) ? "unzip" : "tar"
      ensure_command!(tool)
      tool_args = tool == "unzip" ? ["unzip", "-Z1", path] : ["tar", "-tf", path]
      argv, process_env, spawn_options = archive_command(tool_args)

      count = 0
      listed_bytes = 0
      diagnostic = +""
      status = nil
      Open3.popen2e(process_env, *argv, **spawn_options) do |stdin, io, wait_thr|
        stdin.close
        io.each_line("\n", 16 * 1024) do |raw_entry|
          listed_bytes += raw_entry.bytesize
          diagnostic << raw_entry if diagnostic.bytesize < 4096
          raise "Archive listing exceeds #{MAX_ARCHIVE_LIST_BYTES} bytes" if listed_bytes > MAX_ARCHIVE_LIST_BYTES
          if raw_entry.bytesize == 16 * 1024 && !raw_entry.end_with?("\n")
            raise "Archive entry name exceeds 16 KiB"
          end
          entry = raw_entry.strip
          next if entry.empty?
          count += 1
          raise "Archive has too many entries (#{count} > #{MAX_EXTRACTED_FILES})" if count > MAX_EXTRACTED_FILES
          normalized = entry.tr("\\", "/")
          clean = Pathname.new(normalized).cleanpath.to_s
          if normalized.start_with?("/") || clean == ".." || clean.start_with?("../") || normalized.include?("\0")
            raise "Unsafe archive entry: #{entry.inspect}"
          end
        end
        status = wait_thr.value
      end
      unless status&.success?
        detail = diagnostic.byteslice(0, 4096).to_s.strip
        raise "Could not inspect archive #{File.basename(path)}#{": #{detail}" unless detail.empty?}"
      end
      validate_archive_metadata!(path, tool, expected_count: count)
      true
    end

    def validate_archive_metadata!(path, tool, expected_count:)
      tool_args = if tool == "unzip"
                    ["unzip", "-Z", "-l", path]
                  else
                    ["tar", "--list", "--verbose", "--numeric-owner", "--file", path]
                  end
      argv, process_env, spawn_options = archive_command(tool_args)
      count = 0
      total_bytes = 0
      listed_bytes = 0
      diagnostic = +""
      status = nil

      Open3.popen2e(process_env, *argv, **spawn_options) do |stdin, io, wait_thr|
        stdin.close
        io.each_line("\n", 16 * 1024) do |line|
          listed_bytes += line.bytesize
          diagnostic << line if diagnostic.bytesize < 4096
          raise "Archive metadata exceeds #{MAX_ARCHIVE_LIST_BYTES} bytes" if listed_bytes > MAX_ARCHIVE_LIST_BYTES
          if line.bytesize == 16 * 1024 && !line.end_with?("\n")
            raise "Archive metadata line exceeds 16 KiB"
          end

          fields = line.strip.split(/\s+/)
          if tool == "unzip"
            next unless fields.length >= 4 && fields[1]&.match?(/\A\d+(?:\.\d+)?\z/) && fields[3]&.match?(/\A\d+\z/)
            kind = fields[0].to_s[0]
            raise "Archive contains unsupported special-file entry" if %w[b c p s].include?(kind)
            size_field = fields[3]
          else
            next unless fields[0]&.match?(/\A[-dlhbcps][rwxStTs-]{9}[+@.]?\z/)
            kind = fields[0][0]
            raise "Archive contains unsupported special-file entry" unless %w[- d l h].include?(kind)
            size_field = fields[2]
          end
          size = Integer(size_field, exception: false)
          raise "Could not parse archive entry size" unless size && size >= 0

          count += 1
          total_bytes += size
          raise "Archive expands beyond #{MAX_EXTRACTED_BYTES} bytes" if total_bytes > MAX_EXTRACTED_BYTES
        end
        status = wait_thr.value
      end

      unless status&.success?
        detail = diagnostic.byteslice(0, 4096).to_s.strip
        raise "Could not inspect archive metadata #{File.basename(path)}#{": #{detail}" unless detail.empty?}"
      end
      raise "Archive metadata entry count mismatch" unless count == expected_count
      true
    end

    def archive_command(tool_args)
      tool = tool_args.first
      if SandboxManager.enabled?
        argv = SandboxManager.command_for(
          Shellwords.join(tool_args),
          cwd: @build_dir,
          writable_paths: [],
          readable_paths: [@build_dir, *sandbox_readable_paths],
          environment: safe_build_environment,
          network: ENV["QUARKS_BUILD_NETWORK"] == "1"
        )
        [argv, safe_host_environment, { unsetenv_others: true }]
      else
        trusted_tool = %W[/usr/bin/#{tool} /bin/#{tool}].find { |candidate| File.executable?(candidate) }
        raise "Trusted system tool not found: #{tool}" unless trusted_tool
        [[trusted_tool, *tool_args.drop(1)], safe_host_environment, { unsetenv_others: true }]
      end
    end

    def validate_extracted_tree!(dest)
      root = File.realpath(dest)
      count = 0
      bytes = 0
      Find.find(dest) do |entry|
        next if entry == dest
        count += 1
        raise "Extracted tree exceeds #{MAX_EXTRACTED_FILES} entries" if count > MAX_EXTRACTED_FILES
        stat = File.lstat(entry)
        unless stat.directory? || stat.file? || stat.symlink?
          raise "Extracted tree contains an unsupported special file: #{entry}"
        end
        if stat.symlink?
          target = File.readlink(entry)
          raise "Extracted tree contains an absolute symlink: #{entry}" if target.start_with?("/")
          resolved = File.expand_path(target, File.dirname(entry))
          unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
            raise "Extracted symlink escapes the source tree: #{entry} -> #{target}"
          end
        end
        next unless stat.file?
        bytes += stat.size
        raise "Extracted tree exceeds #{MAX_EXTRACTED_BYTES} bytes" if bytes > MAX_EXTRACTED_BYTES
      end
    end

    def copy_into_build_dir(path)
      target = File.join(@build_dir, File.basename(path))
      if File.directory?(path)
        FileUtils.cp_r(path, target, remove_destination: true)
      else
        FileUtils.cp(path, target)
      end
    end

    def detect_source_dir!
      return @source_dir if @source_dir && Dir.exist?(@source_dir)
      return @build_dir if source_tree_score(@build_dir).positive?

      top_dirs = Dir.children(@build_dir).map { |entry| File.join(@build_dir, entry) }.select { |p| File.directory?(p) }
      return top_dirs.first if top_dirs.length == 1

      candidates = [@build_dir]
      Find.find(@build_dir) do |path|
        next unless File.directory?(path)
        rel = path.delete_prefix(@build_dir).sub(%r{^/}, "")
        depth = rel.empty? ? 0 : rel.count("/")
        next if depth > 2
        candidates << path
      end

      ranked = candidates.uniq.map { |dir| [dir, source_tree_score(dir)] }
      best = ranked.max_by { |(_, score)| score }
      best && best[1].positive? ? best[0] : @build_dir
    end

    def source_tree_score(dir)
      return 0 unless Dir.exist?(dir)

      score = 0
      score += 10 if File.exist?(File.join(dir, "meson.build"))
      score += 10 if File.exist?(File.join(dir, "CMakeLists.txt"))
      score += 10 if File.exist?(File.join(dir, "configure"))
      score += 8  if File.exist?(File.join(dir, "Makefile"))
      score += 8  if File.exist?(File.join(dir, "GNUmakefile"))
      score += 8  if File.exist?(File.join(dir, "build.ninja"))
      score += 5  if File.exist?(File.join(dir, "README")) || File.exist?(File.join(dir, "README.md"))
      score += 5  if Dir.exist?(File.join(dir, "src"))
      score
    end

    def apply_patches
      patches = Array(@package.patches)
      return if patches.empty?

      say_phase("Applying patches", :info)
      ensure_command!("patch")

      patches.each do |patch_entry|
        file = patch_entry[:file] || patch_entry["file"]
        strip = (patch_entry[:strip] || patch_entry["strip"] || 1).to_i
        patch_path = resolve_patch_path(file.to_s)
        raise "Patch not found: #{file}" unless patch_path

        say_detail("Applying #{File.basename(patch_path)} (-p#{strip})")
        if patch_applies?(patch_path, strip: strip)
          run_shell!("patch -p#{strip} < #{shell_escape(patch_path)}", cwd: @source_dir || @build_dir, env: {})
        else
          raise "Patch does not apply cleanly: #{file}"
        end
      end
    end

    def resolve_patch_path(ref)
      candidates = [
        File.join(@source_dir || @build_dir, ref)
      ].uniq

      candidates.find { |path| File.file?(path) }
    end

    def patch_applies?(patch_path, strip:)
      cmd = "patch --dry-run -p#{strip} < #{shell_escape(patch_path)}"
      run_shell!(cmd, cwd: @source_dir || @build_dir, env: {}, quiet: true)
      true
    rescue
      false
    end

    def create_build_plan
      system = normalize_build_system(@package.build_system)
      system = auto_detect_build_system if system == :auto

      source_dir = @source_dir || @build_dir
      plan_build_dir = build_work_dir_for(system, source_dir)

      custom_build_cmds   = interpolate_commands(Array(@package.build_commands), source_dir, plan_build_dir)
      custom_install_cmds = interpolate_commands(Array(@package.install_commands), source_dir, plan_build_dir)

      configure_cmds, build_cmds = split_custom_build_commands(custom_build_cmds)

      case system
      when :meson
        if custom_build_cmds.empty?
          configure_cmds = default_meson_configure(source_dir, plan_build_dir)
          build_cmds     = default_meson_build(plan_build_dir)
          install_cmds   = default_meson_install(plan_build_dir)
        else
          install_cmds = custom_install_cmds
        end
      when :cmake
        if custom_build_cmds.empty?
          configure_cmds = default_cmake_configure(source_dir, plan_build_dir)
          build_cmds     = default_cmake_build(plan_build_dir)
          install_cmds   = default_cmake_install(plan_build_dir)
        else
          install_cmds = custom_install_cmds
        end
      when :autotools
        if custom_build_cmds.empty?
          configure_cmds = default_autotools_configure(source_dir)
          build_cmds     = default_make_build
          install_cmds   = default_make_install
        else
          configure_cmds = configure_cmds.map { |command| autotools_configure_with_prefix(command) }
          install_cmds = custom_install_cmds
        end
      when :make
        if custom_build_cmds.empty?
          configure_cmds = []
          build_cmds     = default_make_build
          install_cmds   = default_make_install
        else
          install_cmds = custom_install_cmds
        end
      when :ninja
        if custom_build_cmds.empty?
          configure_cmds = []
          build_cmds     = default_ninja_build(source_dir)
          install_cmds   = default_ninja_install(source_dir)
        else
          install_cmds = custom_install_cmds
        end
      when :manual
        configure_cmds, build_cmds = split_custom_build_commands(custom_build_cmds)
        install_cmds = custom_install_cmds
        if configure_cmds.empty? && build_cmds.empty? && install_cmds.empty?
          raise "Manual build system selected, but no build/install commands were provided"
        end
      else
        raise "Unsupported build system: #{system}"
      end

      BuildPlan.new(
        system: system,
        cwd: source_dir,
        build_dir: plan_build_dir,
        configure_cmds: configure_cmds,
        build_cmds: build_cmds,
        install_cmds: install_cmds
      )
    end

    def split_custom_build_commands(commands)
      configure_cmds = []
      build_cmds = []

      Array(commands).each do |cmd|
        if configure_like_command?(cmd)
          configure_cmds << cmd
        else
          build_cmds << cmd
        end
      end

      [configure_cmds, build_cmds]
    end

    def configure_like_command?(cmd)
      s = cmd.to_s.strip
      return true if s.start_with?("./configure", "configure ", "./bootstrap", "bootstrap ")
      return true if s.include?(" cmake ") || s.start_with?("cmake ") || s.include?(" meson setup") || s.start_with?("meson setup")
      false
    end

    def normalize_build_system(value)
      return :auto if value.nil?
      value.to_s.strip.empty? ? :auto : value.to_s.strip.downcase.to_sym
    end

    def auto_detect_build_system
      dir = @source_dir || @build_dir
      return :meson     if File.exist?(File.join(dir, "meson.build"))
      return :cmake     if File.exist?(File.join(dir, "CMakeLists.txt"))
      return :autotools if File.exist?(File.join(dir, "configure"))
      return :ninja     if File.exist?(File.join(dir, "build.ninja"))
      return :make      if File.exist?(File.join(dir, "Makefile")) || File.exist?(File.join(dir, "GNUmakefile"))
      return :manual    unless Array(@package.build_commands).empty? && Array(@package.install_commands).empty?

      :manual
    end

    def build_work_dir_for(system, source_dir)
      case system
      when :meson, :cmake
        File.join(source_dir, @package.build_dir.to_s.empty? ? "build" : @package.build_dir.to_s)
      else
        source_dir
      end
    end

    def interpolate_commands(commands, srcdir, builddir)
      commands.map do |cmd|
        s = cmd.to_s.dup
        s.gsub!("%{srcdir}", shell_escape(srcdir))
        s.gsub!("%{builddir}", shell_escape(builddir))
        s.gsub!("%{destdir}", shell_escape(@dest_dir))
        s.gsub!("%{prefix}", shell_escape(@package.install_prefix.to_s))
        s.gsub!("%{jobs}", @jobs.to_s)
        s.gsub!("%{cmake_args}", Shellwords.join(Array(@package.cmake_args).map(&:to_s)))
        s.gsub!("%{meson_args}", Shellwords.join(Array(@package.meson_args).map(&:to_s)))
        s.gsub!("%{make_args}", Shellwords.join(Array(@package.make_args).map(&:to_s)))
        s
      end.reject(&:empty?)
    end

    def default_meson_configure(source_dir, build_dir)
      FileUtils.mkdir_p(build_dir)
      args = Shellwords.join(Array(@package.meson_args).map(&:to_s))
      [[
        "meson setup",
        shell_escape(build_dir),
        shell_escape(source_dir),
        "--prefix=#{shell_escape(@package.install_prefix)}",
        args
      ].reject(&:empty?).join(" ")]
    end

    def default_meson_build(build_dir)
      ["meson compile -C #{shell_escape(build_dir)} -j #{@jobs}"]
    end

    def default_meson_install(build_dir)
      ["DESTDIR=#{shell_escape(@dest_dir)} meson install -C #{shell_escape(build_dir)}"]
    end

    def default_cmake_configure(source_dir, build_dir)
      FileUtils.mkdir_p(build_dir)
      args = Shellwords.join(Array(@package.cmake_args).map(&:to_s))
      [[
        "cmake",
        "-S #{shell_escape(source_dir)}",
        "-B #{shell_escape(build_dir)}",
        "-DCMAKE_INSTALL_PREFIX=#{shell_escape(@package.install_prefix)}",
        args
      ].reject(&:empty?).join(" ")]
    end

    def default_cmake_build(build_dir)
      ["cmake --build #{shell_escape(build_dir)} --parallel #{@jobs}"]
    end

    def default_cmake_install(build_dir)
      ["DESTDIR=#{shell_escape(@dest_dir)} cmake --install #{shell_escape(build_dir)}"]
    end

    def default_autotools_configure(_source_dir)
      flags = Shellwords.join(Array(@package.configure_flags).map(&:to_s))
      [["./configure", "--prefix=#{shell_escape(@package.install_prefix)}", flags].reject(&:empty?).join(" ")]
    end

    def autotools_configure_with_prefix(command)
      value = command.to_s.strip
      return value if value.match?(/(?:\A|\s)--prefix(?:=|\s)/)

      "#{value} --prefix=#{shell_escape(@package.install_prefix)}"
    end

    def default_make_build
      args = Shellwords.join(Array(@package.make_args).map(&:to_s))
      ["make -j#{@jobs} #{args}".strip]
    end

    def default_make_install
      prefix = @package.install_prefix.to_s
      args = Shellwords.join(Array(@package.make_args).map(&:to_s))
      ["make DESTDIR=#{shell_escape(@dest_dir)} PREFIX=#{shell_escape(prefix)} #{args} install".strip]
    end

    def default_ninja_build(source_dir)
      if File.exist?(File.join(source_dir, "build.ninja"))
        ["ninja -j#{@jobs}"]
      else
        raise "Ninja build selected, but build.ninja was not found"
      end
    end

    def default_ninja_install(_source_dir)
      ["DESTDIR=#{shell_escape(@dest_dir)} ninja install"]
    end

    def build_env(plan)
      env = {}
      env.merge!(stringify_hash(@package.environment))

      env["DESTDIR"] = @dest_dir
      env["PREFIX"] = @package.install_prefix.to_s
      env["JOBS"] = @jobs.to_s
      env["MAKEFLAGS"] ||= "-j#{@jobs}"
      env["QUARKS_SRCDIR"] = @source_dir || @build_dir
      env["QUARKS_BUILDDIR"] = plan.build_dir || @source_dir || @build_dir
      env["QUARKS_DESTDIR"] = @dest_dir
      env["QUARKS_PKG_NAME"] = @package.name.to_s
      env["QUARKS_PKG_VERSION"] = @package.version.to_s
      env["QUARKS_USE"] = @use_flags.join(" ")
      env["USE"] = @use_flags.join(" ")
      env["QUARKS_ENABLED_USE"] = @use_flags.reject { |flag| flag.start_with?("-") }.join(" ")
      env.merge!(dependency_environment)
      env
    end

    def dependency_environment
      root = File.expand_path(Quarks::Env.root)
      return {} if root == File::SEPARATOR || !Dir.exist?(root)

      bins = %w[usr/bin usr/sbin usr/local/bin usr/local/sbin bin sbin]
             .map { |path| File.join(root, path) }.select { |path| Dir.exist?(path) }
      includes = %w[usr/include usr/local/include include]
                 .map { |path| File.join(root, path) }.select { |path| Dir.exist?(path) }
      libraries = %w[usr/lib usr/lib64 usr/local/lib usr/local/lib64 lib lib64]
                  .map { |path| File.join(root, path) }.select { |path| Dir.exist?(path) }
      pkgconfig = libraries.map { |path| File.join(path, "pkgconfig") }.select { |path| Dir.exist?(path) }
      share_pkgconfig = File.join(root, "usr", "share", "pkgconfig")
      pkgconfig << share_pkgconfig if Dir.exist?(share_pkgconfig)
      cmake = [root, File.join(root, "usr"), File.join(root, "usr", "local")].select { |path| Dir.exist?(path) }

      environment = {}
      environment["PATH"] = (bins + [safe_build_environment.fetch("PATH")]).join(File::PATH_SEPARATOR) if bins.any?
      environment["CPATH"] = includes.join(File::PATH_SEPARATOR) if includes.any?
      environment["LIBRARY_PATH"] = libraries.join(File::PATH_SEPARATOR) if libraries.any?
      environment["LD_LIBRARY_PATH"] = libraries.join(File::PATH_SEPARATOR) if libraries.any?
      environment["PKG_CONFIG_PATH"] = pkgconfig.join(File::PATH_SEPARATOR) if pkgconfig.any?
      environment["CMAKE_PREFIX_PATH"] = cmake.join(File::PATH_SEPARATOR) if cmake.any?
      environment
    end

    def run_commands(commands, cwd:, env:, phase:)
      phase_title = case phase
                    when "configure" then "Configure"
                    when "build" then "Build"
                    when "install" then "Install"
                    else phase.capitalize
                    end

      Array(commands).each do |cmd|
        next if cmd.to_s.strip.empty?
        say_phase("#{phase_title}: #{pretty_command_title(cmd)}", :info)
        run_shell!(cmd, cwd: cwd, env: env)
      end
    end

    def run_shell!(cmd, cwd:, env:, quiet: false, writable_paths: nil)
      log_line("")
      log_line("$ #{cmd}")
      log_line("cwd=#{cwd}")
      log_line("env=#{env.inspect}") if @debug

      status = nil
      command_env = safe_build_environment.merge(stringify_hash(env))
      if SandboxManager.enabled?
        argv = SandboxManager.command_for(
          cmd,
          cwd: cwd,
          writable_paths: writable_paths || [@build_dir, @dest_dir],
          readable_paths: sandbox_readable_paths,
          environment: command_env,
          network: ENV["QUARKS_BUILD_NETWORK"] == "1"
        )
        process_env = safe_host_environment
        spawn_options = { unsetenv_others: true }
      else
        argv = ["/bin/bash", "-lc", cmd.to_s]
        process_env = command_env
        spawn_options = { chdir: cwd, unsetenv_others: true }
      end

      Open3.popen2e(process_env, *argv, **spawn_options) do |_stdin, io, wait_thr|
        io.each_line("\n", MAX_OUTPUT_LINE_BYTES) do |line|
          display_line = line.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�")
          log_line(display_line.chomp)
          stream_line(display_line, quiet: quiet)
        end
        status = wait_thr.value
      end

      Quarks::SignalHandler.instance.check_and_raise! if defined?(Quarks::SignalHandler)
      return true if status&.success?
      raise "Command failed (exit #{status&.exitstatus || 'unknown'}): #{cmd}"
    end

    def safe_build_environment
      {
        "PATH" => "/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin",
        "LANG" => "C.UTF-8",
        "LC_ALL" => "C.UTF-8",
        "TZ" => "UTC"
      }
    end

    def safe_host_environment
      { "PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C" }
    end

    def sandbox_readable_paths
      paths = [@cache_dir]
      install_root = File.expand_path(Quarks::Env.root)
      paths << install_root unless install_root == File::SEPARATOR
      paths
    end

    def stream_line(line, quiet: false)
      return if quiet || @quiet
      if defined?(Quarks::UI) && Quarks::UI.respond_to?(:pretty_build_line)
        Quarks::UI.pretty_build_line(line, debug: @debug)
      else
        puts line unless @quiet
      end
    end

    def finalize_destdir!
      files = []
      Find.find(@dest_dir) do |path|
        files << path if File.file?(path) || File.symlink?(path)
      end

      raise "Install phase produced no files in #{@dest_dir}" if files.empty?
    end

    def ensure_command!(name)
      return if command_exists?(name)
      raise "Required command not found on PATH: #{name}"
    end

    def command_exists?(name)
      key = [ENV.fetch("PATH", ""), name.to_s]
      return @command_cache[key] if @command_cache.key?(key)
      @command_cache[key] = key[0].split(File::PATH_SEPARATOR).any? do |directory|
        File.executable?(File.join(directory, key[1]))
      end
    end

    def stringify_hash(hash)
      hash.each_with_object({}) { |(k, v), out| out[k.to_s] = v.to_s }
    end

    def safe_slug(value)
      value.to_s.gsub(/[^a-zA-Z0-9._-]+/, "-").gsub(/-+/, "-").sub(/\A-/, "").sub(/-\z/, "")
    end

    def shell_escape(value)
      Shellwords.escape(value.to_s)
    end

    def pretty_command_title(cmd)
      stripped = cmd.to_s.strip
      return stripped if stripped.length <= 88
      "#{stripped[0, 85]}..."
    end

    def say_phase(message, type = :info)
      return if @quiet && type == :info

      prefix =
        case type
        when :warn then "#{Quarks::UI::COLORS[:yellow]}>>>#{Quarks::UI::COLORS[:reset]}"
        when :error then "#{Quarks::UI::COLORS[:red]}!!!#{Quarks::UI::COLORS[:reset]}"
        else "#{Quarks::UI::COLORS[:green]}>>>#{Quarks::UI::COLORS[:reset]}"
        end

      puts "#{prefix} #{message}"
    rescue
      puts ">>> #{message}"
    end

    def say_detail(message)
      return unless @verbose || @debug
      if defined?(Quarks::UI)
        puts "#{Quarks::UI::COLORS[:dim]}#{message}#{Quarks::UI::COLORS[:reset]}"
      else
        puts message
      end
    end

    def log_header(title)
      log_line("")
      log_line("=" * 80)
      log_line("[#{Time.now.iso8601}] #{title}")
      log_line("=" * 80)
    end

    def log_line(line)
      return if @log_truncated

      data = "#{line}\n"
      remaining = MAX_LOG_BYTES - @log_bytes
      if data.bytesize > remaining
        marker = "\n[quarks] Build log truncated at #{MAX_LOG_BYTES} bytes\n"
        fragment_size = [remaining - marker.bytesize, 0].max
        data = data.byteslice(0, fragment_size).to_s + marker.byteslice(0, remaining).to_s
        @log_truncated = true
      end
      open_log!
      @log_io.write(data)
      @log_bytes += data.bytesize
    rescue
      nil
    end

    def open_log!
      return @log_io if @log_io && !@log_io.closed?
      Security.secure_directory(@log_dir)
      raise "Build log path is a symlink: #{@log_file}" if File.symlink?(@log_file)
      @log_io = File.open(@log_file, File::WRONLY | File::CREAT | File::APPEND, 0o600)
      File.chmod(0o600, @log_file)
      @log_io
    end

    def close_log!
      return unless @log_io
      @log_io.flush unless @log_io.closed?
      @log_io.close unless @log_io.closed?
    rescue
      nil
    ensure
      @log_io = nil
    end

    def build_error_with_log(error)
      @log_io&.flush
      tail = begin
        File.open(@log_file, "rb") do |file|
          bytes = [file.size, 256 * 1024].min
          file.seek(-bytes, IO::SEEK_END) if bytes.positive?
          file.read.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "�").lines.last(25).join
        end
      rescue
        nil
      end

      msg = +"#{error.message}\n\nBuild log: #{@log_file}"
      msg << "\n\nLast log lines:\n#{tail}" unless tail.nil? || tail.strip.empty?
      RuntimeError.new(msg)
    end
  end
end
