# frozen_string_literal: true

require "fileutils"
require "open3"
require "net/http"
require "uri"
require "openssl"
require "digest"
require "find"
require "shellwords"
require "time"

require "quarks/env"
require "quarks/hash_verifier"

module Quarks
  class Builder
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
      @jobs    = (@options[:jobs].to_i.positive? ? @options[:jobs].to_i : Quarks::Env.jobs)

      tmp_root   = Quarks::Env.tmpdir rescue (ENV["QUARKS_TMPDIR"] || "/var/tmp/quarks")
      build_root = File.join(tmp_root, "quarks-build")
      dest_root  = File.join(tmp_root, "quarks-dest")

      slug = safe_slug(@package.full_name)

      @build_dir = File.join(build_root, slug)
      @dest_dir  = File.join(dest_root, slug)

      state_root = Quarks::Env.state_root rescue (ENV["QUARKS_STATE_ROOT"] || File.expand_path("~/.local/state/quarks"))
      @cache_dir = File.join(state_root, "var", "cache", "quarks", "distfiles")
      @log_dir   = File.join(state_root, "var", "log", "quarks")
      FileUtils.mkdir_p(@log_dir)
      @log_file  = File.join(@log_dir, "#{slug}.log")

      @source_dir = nil
      @downloaded_sources = []
    end

    def fetch_only
      prepare_directories
      @downloaded_sources = download_sources
      true
    end

    def build
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
      raise build_error_with_log(e)
    end

    private

    def prepare_directories
      FileUtils.mkdir_p(@cache_dir)
      FileUtils.mkdir_p(@log_dir)

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
      if local_path
        say_detail("Using local source #{File.basename(local_path)}")
        verify_source!(local_path, source)
        return local_path
      end

      uri = URI.parse(source)
      filename = cache_filename_for(uri, index)
      cached_path = File.join(@cache_dir, filename)

      if File.exist?(cached_path) && cached_source_valid?(cached_path, source)
        say_detail("Using cached source #{filename}")
        return cached_path
      end

      say_detail("Downloading #{source}")
      download_http(uri, cached_path)
      verify_source!(cached_path, source)
      cached_path
    rescue URI::InvalidURIError
      raise "Invalid source URL/path: #{source}"
    end

    def resolve_local_source(source)
      if source.start_with?("file://")
        path = URI.parse(source).path
        return File.expand_path(path) if File.exist?(path)
        return nil
      end

      return File.expand_path(source) if File.exist?(source)
      nil
    rescue
      nil
    end

    def cache_filename_for(uri, index)
      base = File.basename(uri.path.to_s)
      base = "source-#{index + 1}" if base.nil? || base.empty? || base == "/"

      if uri.query && !uri.query.empty?
        digest = Digest::SHA256.hexdigest(uri.to_s)[0, 12]
        "#{base}.#{digest}"
      else
        base
      end
    end

    def cached_source_valid?(path, source)
      verify_source!(path, source)
      true
    rescue
      FileUtils.rm_f(path) rescue nil
      false
    end

    def verify_source!(path, source_key)
      checksum = lookup_checksum(source_key)
      return true unless checksum

      expected_hash = checksum[:hash].to_s.strip
      algorithm = checksum[:algorithm].to_s.strip
      algorithm = "sha256" if algorithm.empty?

      if expected_hash == "skip"
        if Quarks::Env.allow_insecure?
          say_detail("Skipping checksum verification for #{File.basename(path)}")
          return true
        end
        raise "Insecure package source: checksum is set to 'skip' for #{source_key}"
      end

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

    def download_http(uri, dest)
      max_redirects = 5
      current_uri = uri

      max_redirects.times do
        response = nil

        Net::HTTP.start(
          current_uri.host,
          current_uri.port,
          use_ssl: current_uri.scheme == "https",
          open_timeout: 15,
          read_timeout: 180,
          ssl_timeout: 15
        ) do |http|
          request = Net::HTTP::Get.new(current_uri)
          request["User-Agent"] = "Quarks/#{Quarks::VERSION rescue 'dev'}"
          response = http.request(request)
        end

        case response
        when Net::HTTPSuccess
          tmp = "#{dest}.part-#{Process.pid}"
          begin
            File.open(tmp, "wb") { |f| f.write(response.body) }
            FileUtils.mv(tmp, dest)
          ensure
            FileUtils.rm_f(tmp) if File.exist?(tmp)
          end
          return dest
        when Net::HTTPRedirection
          location = response["location"].to_s
          raise "Redirect missing location for #{current_uri}" if location.empty?
          current_uri = URI.join(current_uri.to_s, location)
        else
          raise "Download failed: HTTP #{response.code} #{response.message}"
        end
      end

      raise "Too many redirects while fetching #{uri}"
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

      if path =~ /\.zip$/i
        ensure_command!("unzip")
        run_shell!(
          "unzip -q #{shell_escape(path)} -d #{shell_escape(dest)}",
          cwd: dest,
          env: {}
        )
      else
        ensure_command!("tar")
        run_shell!(
          "tar -xf #{shell_escape(path)} -C #{shell_escape(dest)}",
          cwd: dest,
          env: {}
        )
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
        ref,
        File.expand_path(ref),
        File.join(Dir.pwd, ref),
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
        s.gsub!("%{srcdir}", srcdir)
        s.gsub!("%{builddir}", builddir)
        s.gsub!("%{destdir}", @dest_dir)
        s.gsub!("%{prefix}", @package.install_prefix.to_s)
        s.gsub!("%{jobs}", @jobs.to_s)
        s
      end.reject(&:empty?)
    end

    def default_meson_configure(source_dir, build_dir)
      FileUtils.mkdir_p(build_dir)
      args = Array(@package.meson_args).map(&:to_s).join(" ")
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
      args = Array(@package.cmake_args).map(&:to_s).join(" ")
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
      flags = Array(@package.configure_flags).map(&:to_s).join(" ")
      [["./configure", "--prefix=#{shell_escape(@package.install_prefix)}", flags].reject(&:empty?).join(" ")]
    end

    def default_make_build
      args = Array(@package.make_args).map(&:to_s).join(" ")
      ["make -j#{@jobs} #{args}".strip]
    end

    def default_make_install
      prefix = @package.install_prefix.to_s
      args = Array(@package.make_args).map(&:to_s).join(" ")
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
      env
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

    def run_shell!(cmd, cwd:, env:, quiet: false)
      log_line("")
      log_line("$ #{cmd}")
      log_line("cwd=#{cwd}")
      log_line("env=#{env.inspect}") if @debug

      status = nil
      Open3.popen2e(env, "bash", "-lc", cmd, chdir: cwd) do |_stdin, io, wait_thr|
        io.each_line do |line|
          log_line(line.chomp)
          stream_line(line, quiet: quiet)
        end
        status = wait_thr.value
      end

      return true if status&.success?
      raise "Command failed (exit #{status&.exitstatus || 'unknown'}): #{cmd}"
    end

    def stream_line(line, quiet: false)
      return if quiet
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
      system("command -v #{Shellwords.escape(name)} >/dev/null 2>&1")
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
      File.open(@log_file, "a") do |f|
        f.puts("")
        f.puts("=" * 80)
        f.puts("[#{Time.now.iso8601}] #{title}")
        f.puts("=" * 80)
      end
    rescue
      nil
    end

    def log_line(line)
      File.open(@log_file, "a") { |f| f.puts(line) }
    rescue
      nil
    end

    def build_error_with_log(error)
      tail = begin
        File.readlines(@log_file).last(25).join
      rescue
        nil
      end

      msg = +"#{error.message}\n\nBuild log: #{@log_file}"
      msg << "\n\nLast log lines:\n#{tail}" unless tail.nil? || tail.strip.empty?
      RuntimeError.new(msg)
    end
  end
end
