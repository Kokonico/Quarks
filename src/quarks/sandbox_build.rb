# frozen_string_literal: true

require "fileutils"
require "shellwords"

module Quarks
  class SandboxManager
    SANDBOX_SCRIPT = File.join(Quarks::Env.state_root, "var", "tmp", "quarks", "sandbox.sh")

    def self.enabled?
      return false if ENV["QUARKS_NO_SANDBOX"] == "1"
      return true if File.exist?("/usr/bin/sandbox")
      return true if File.exist?("/usr/sbin/sandbox")

      false
    end

    def self.sandbox_env
      {
        "SANDBOX_WRITE" => "/dev/null:/dev/tty:/dev/urandom:/var/tmp:/tmp",
        "SANDBOX_READ" => "/:/dev/null",
        "SANDBOX_X11" => "0",
        "SANDBOX_NETWORK" => "1"
      }
    end

    def self.wrap_command(cmd, cwd: nil, env: {})
      return cmd unless enabled?

      script = generate_sandbox_script(cmd, cwd: cwd, env: env)

      ["/bin/bash", script]
    end

    def self.generate_sandbox_script(cmd, cwd: nil, env: {})
      FileUtils.mkdir_p(File.dirname(SANDBOX_SCRIPT))

      lines = [
        "#!/bin/bash",
        "",
        "export HOME=\"#{ENV['HOME'] || '/tmp'}\"",
        "export SHELL=/bin/bash",
        "export TERM=${TERM:-dumb}",
        "",
        "# Build directories",
        "export QUARKS_BUILD=#{Quarks::Env.tmpdir}/quarks-build",
        "export QUARKS_DEST=#{Quarks::Env.tmpdir}/quarks-dest",
        "",
        "# User environment",
        "export PATH=/usr/bin:/bin:/usr/local/bin",
        "export MAKEFLAGS=-j#{Quarks::Env.jobs}",
        "",
        "# Sandbox environment variables"
      ]

      sandbox_env.each do |key, value|
        lines << "export #{key}=\"#{value}\""
      end

      env.each do |key, value|
        lines << "export #{key}=\"#{value}\""
      end

      lines << ""
      lines << "cd #{cwd || Quarks::Env.tmpdir}" if cwd
      lines << ""
      lines << cmd
      lines << ""

      File.write(SANDBOX_SCRIPT, lines.join("\n"))
      File.chmod(0755, SANDBOX_SCRIPT)

      SANDBOX_SCRIPT
    end
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

      File.open(WORLD_FILE, "a") do |f|
        f.puts(normalized)
      end

      true
    end

    def remove(atom)
      return false if atom.nil? || atom.to_s.strip.empty?

      normalized = normalize_atom(atom)

      original = contents.dup
      return false unless original.include?(normalized)

      new_contents = original.reject { |a| a == normalized || a == atom }
      File.write(WORLD_FILE, new_contents.join("\n") + "\n")

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
      parts_a = parse_version(a)
      parts_b = parse_version(b)
      (parts_a <=> parts_b) == 1
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
