# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "shellwords"
require "time"
require "timeout"
require "quarks/env"
require "quarks/signal_handler"
require "quarks/version"
require "quarks/security"

module Quarks
  class SandboxManager
    class SandboxUnavailable < StandardError; end
    BWRAP_PATHS = %w[/usr/bin/bwrap /bin/bwrap].freeze

    def self.available?
      !bwrap_path.nil?
    end

    def self.enabled?
      ENV["QUARKS_NO_SANDBOX"] != "1"
    end

    def self.operational?(network: false)
      probe(network: network).first
    end

    def self.assert_operational!(network: false)
      usable, reason = probe(network: network)
      return true if usable

      raise SandboxUnavailable, "bubblewrap cannot provide the required build isolation: #{reason}"
    end

    def self.probe(network: false)
      return [false, "trusted /usr/bin/bwrap or /bin/bwrap is not installed"] unless available?

      @probe_results ||= {}
      return @probe_results[network] if @probe_results.key?(network)

      argv = [
        bwrap_path,
        "--die-with-parent",
        "--new-session",
        "--unshare-all",
        "--ro-bind", "/usr", "/usr",
        "--ro-bind", "/etc", "/etc",
        "--symlink", "usr/bin", "/bin",
        "--symlink", "usr/sbin", "/sbin",
        "--symlink", "usr/lib", "/lib",
        "--symlink", "usr/lib64", "/lib64",
        "--dev", "/dev",
        "--proc", "/proc"
      ]
      argv << "--share-net" if network
      argv << "/bin/true"

      Timeout.timeout(5) do
        output, status = Open3.capture2e(
          { "PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C" },
          *argv,
          unsetenv_others: true
        )
        reason = output.to_s.strip.byteslice(0, 1024)
        reason = "probe exited with status #{status.exitstatus}" if reason.to_s.empty? && !status.success?
        @probe_results[network] = [status.success?, reason]
      end
    rescue SystemCallError, Timeout::Error => e
      [false, e.message]
    end

    def self.command_for(cmd, cwd:, writable_paths:, readable_paths: [], environment: {}, network: false)
      return ["/bin/bash", "-lc", cmd.to_s] unless enabled?
      raise SandboxUnavailable, "bubblewrap (bwrap) is required for builds" unless available?

      writable_paths = normalized_mount_paths(writable_paths, kind: "writable")
      readable_paths = normalized_mount_paths(readable_paths, kind: "read-only")

      argv = [
        bwrap_path,
        "--die-with-parent",
        "--new-session",
        "--unshare-all",
        "--ro-bind", "/usr", "/usr",
        "--ro-bind", "/etc", "/etc",
        "--symlink", "usr/bin", "/bin",
        "--symlink", "usr/sbin", "/sbin",
        "--symlink", "usr/lib", "/lib",
        "--symlink", "usr/lib64", "/lib64",
        "--dev", "/dev",
        "--proc", "/proc",
        "--tmpfs", "/tmp",
        "--dir", "/tmp/quarks-home",
        "--dir", "/tmp/quarks-cache",
        "--setenv", "HOME", "/tmp/quarks-home",
        "--setenv", "XDG_CACHE_HOME", "/tmp/quarks-cache"
      ]
      argv << "--share-net" if network

      mounts = (writable_paths + readable_paths).uniq
      mount_parents(mounts).each { |path| argv.concat(["--dir", path]) }

      readable_paths.each do |path|
        next unless File.exist?(path)
        argv.concat(["--ro-bind", path, path])
      end

      writable_paths.each do |path|
        next unless Dir.exist?(path)
        argv.concat(["--bind", path, path])
      end

      environment.each do |key, value|
        raise ArgumentError, "Invalid sandbox environment key: #{key.inspect}" unless key.to_s.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
        raise ArgumentError, "Sandbox environment values must not contain NUL" if value.to_s.include?("\0")
        argv.concat(["--setenv", key.to_s, value.to_s])
      end

      argv.concat(["--chdir", File.expand_path(cwd), "/bin/bash", "-lc", cmd.to_s])
      argv
    end

    def self.bwrap_path
      BWRAP_PATHS.find { |path| File.file?(path) && File.executable?(path) }
    end

    def self.mount_parents(paths)
      system_roots = %w[/usr /etc /bin /sbin /lib /lib64 /dev /proc /tmp]
      parents = []
      paths.each do |path|
        current = File.dirname(path)
        while current != "/" && !system_roots.include?(current)
          parents << current
          current = File.dirname(current)
        end
      end
      parents.uniq.sort_by { |path| [path.count(File::SEPARATOR), path] }
    end

    def self.normalized_mount_paths(paths, kind:)
      Array(paths).map { |path| File.expand_path(path.to_s) }.uniq.tap do |expanded|
        if expanded.include?(File::SEPARATOR)
          raise ArgumentError, "Refusing to expose the whole host root as a #{kind} sandbox mount"
        end
      end
    end

    private_class_method :bwrap_path, :mount_parents, :normalized_mount_paths, :probe
  end

  class BuildEnvironment
    attr_reader :package, :build_dir, :dest_dir, :log_file

    def initialize(package, options: {})
      @package = package
      @options = options
      @build_dir = nil
      @dest_dir = nil
      @log_file = nil
      @phase = :idle
      @saved_state = {}
    end

    def setup!
      @phase = :setup
      prepare_directories!
      save_state
    rescue => e
      @phase = :failed
      raise e
    end

    def teardown!
      return if @options[:keep_temp]

      @phase = :teardown

      unless @options[:keep_build]
        FileUtils.rm_rf(@build_dir) if @build_dir && Dir.exist?(@build_dir)
      end

      unless @options[:keep_dest]
        FileUtils.rm_rf(@dest_dir) if @dest_dir && Dir.exist?(@dest_dir)
      end

      @phase = :cleaned
    end

    def save_state
      @saved_state = {
        package: @package.to_h,
        build_dir: @build_dir,
        dest_dir: @dest_dir,
        log_file: @log_file,
        phase: @phase,
        saved_at: Time.now.to_i
      }
    end

    def load_state
      @saved_state
    end

    def resume?
      return false unless SignalHandler.instance.interrupted?
      return false if @saved_state.empty?

      (@saved_state[:saved_at] + 3600) > Time.now.to_i
    end

    def prepare_directories!
      tmp_root = Quarks::Env.tmpdir
      build_root = File.join(tmp_root, "quarks-build")
      dest_root = File.join(tmp_root, "quarks-dest")

      slug = safe_slug(@package.full_name)

      @build_dir = File.join(build_root, slug)
      @dest_dir = File.join(dest_root, slug)

      state_root = Quarks::Env.state_root
      log_dir = File.join(state_root, "var", "log", "quarks")
      FileUtils.mkdir_p(log_dir)
      @log_file = File.join(log_dir, "#{slug}.log")

      unless @options[:resume]
        FileUtils.rm_rf(@build_dir)
        FileUtils.rm_rf(@dest_dir)
      end

      FileUtils.mkdir_p(@build_dir)
      FileUtils.mkdir_p(@dest_dir)

      @phase = :ready
    end

    def safe_slug(value)
      value.to_s.gsub(/[^a-zA-Z0-9._-]+/, "-").gsub(/-+/, "-").sub(/\A-/, "").sub(/-\z/, "")
    end

    def log(msg)
      return unless @log_file

      File.open(@log_file, "a") do |f|
        f.puts("[#{Time.now.iso8601}] #{msg}")
      end
    end

    def log_section(title)
      return unless @log_file

      File.open(@log_file, "a") do |f|
        f.puts("")
        f.puts("=" * 80)
        f.puts(title)
        f.puts("=" * 80)
      end
    end
  end

  class EmergeLogger
    LOG_DIR = File.join(Quarks::Env.state_root, "var", "log", "quarks", "emerge")

    def initialize
      FileUtils.mkdir_p(LOG_DIR)
    end

    def log_emergence(package, phase, details = {})
      timestamp = Time.now
      log_file = current_log_file

      entry = {
        timestamp: timestamp.iso8601,
        package: package.atom,
        version: package.version,
        phase: phase,
        pid: Process.pid
      }.merge(details)

      File.open(log_file, "a") do |f|
        f.puts(JSON.generate(entry))
      end
    end

    def log_success(package, duration)
      log_emergence(package, "success", duration: duration)
    end

    def log_failure(package, error)
      log_emergence(package, "failure", error: error.message, error_class: error.class.to_s)
    end

    def log_skip(package, reason)
      log_emergence(package, "skipped", reason: reason)
    end

    def history(limit: 100)
      entries = []

      Dir.glob(File.join(LOG_DIR, "*.jsonl")).sort_by { |f| File.mtime(f) }.reverse.first(limit).each do |file|
        File.readlines(file).each do |line|
          begin
            entries << JSON.parse(line)
          rescue JSON::ParserError
          end
        end
      end

      entries.sort_by { |e| e["timestamp"] }.reverse.first(limit)
    end

    def recent_failures
      history(limit: 100).select { |e| e["phase"] == "failure" }
    end

    def current_log_file
      date = Time.now.strftime("%Y-%m-%d")
      File.join(LOG_DIR, "emerge-#{date}.jsonl")
    end
  end

  class WorldManager
    WORLD_FILE = File.join(Quarks::Env.state_root, "var", "db", "quarks", "world")

    def initialize
      FileUtils.mkdir_p(File.dirname(WORLD_FILE))
    end

    def add(atom)
      return false if atom.nil? || atom.to_s.strip.empty?

      normalized = normalize_atom(atom)
      return false if contents.include?(normalized)

      Security.atomic_write(WORLD_FILE, (contents + [normalized]).uniq.join("\n") + "\n")

      true
    end

    def remove(atom)
      return false if atom.nil? || atom.to_s.strip.empty?

      normalized = normalize_atom(atom)

      original = contents.dup
      return false unless original.include?(normalized)

      new_contents = original.reject { |a| a == normalized || a == atom }
      Security.atomic_write(WORLD_FILE, new_contents.join("\n") + "\n")

      true
    end

    def contents
      return [] unless File.exist?(WORLD_FILE)

      File.readlines(WORLD_FILE)
          .map(&:strip)
          .reject(&:empty?)
          .uniq
    end

    def includes?(atom)
      normalized = normalize_atom(atom)
      contents.any? do |a|
        a == normalized || a == atom || a.split("/").last == atom
      end
    end

    def update(atom, new_atom = nil)
      return false unless includes?(atom)

      remove(atom)
      add(new_atom) if new_atom

      true
    end

    def sync!(repository, database)
      contents.each do |atom|
        pkg = repository.find_package(atom)
        next if pkg && database.installed?(pkg.name)

        if pkg
          database.world_add(atom)
        else
          remove(atom)
        end
      end
    end

    def explain
      contents.map do |atom|
        info = {
          atom: atom,
          present: false,
          version_current: nil,
          version_available: nil,
          needs_update: false,
          category: nil
        }

        pkg = @repository&.find_package(atom) if defined?(@repository)

        if pkg
          info[:present] = true
          info[:version_available] = pkg.version
          info[:category] = pkg.category

          db_pkg = @database&.get_package(pkg.name) if defined?(@database)

          if db_pkg
            info[:version_current] = db_pkg[:version]
            info[:needs_update] = version_gt?(pkg.version, db_pkg[:version])
          end
        end

        info
      end
    end

    private

    def normalize_atom(atom)
      atom.to_s.strip.downcase
    end

    def version_gt?(a, b)
      Quarks::Versioning.newer?(a, b)
    end

    def parse_version(version)
      version.to_s.scan(/(\d+)|([a-zA-Z]+)/).flatten.compact.map do |part|
        if part =~ /^\d+$/
          part.to_i
        else
          part
        end
      end
    end
  end
end
