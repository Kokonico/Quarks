# frozen_string_literal: true

require "etc"
require "fileutils"

module Quarks
  module Env
    module_function

    def original_user
      sudo_user = ENV["SUDO_USER"].to_s.strip
      return sudo_user unless sudo_user.empty?

      login = begin
        Etc.getlogin.to_s.strip
      rescue
        ""
      end
      return login unless login.empty?

      user = ENV["USER"].to_s.strip
      return user unless user.empty?

      Etc.getpwuid(Process.uid).name
    rescue
      "unknown"
    end

    def home_for(user = original_user)
      Etc.getpwnam(user).dir
    rescue
      Dir.home
    end

    def home
      h = ENV["HOME"].to_s.strip
      h.empty? ? home_for : h
    end

    def xdg_config_home
      v = ENV["XDG_CONFIG_HOME"].to_s.strip
      v.empty? ? File.join(home_for, ".config") : File.expand_path(v)
    end

    def xdg_state_home
      v = ENV["XDG_STATE_HOME"].to_s.strip
      v.empty? ? File.join(home_for, ".local", "state") : File.expand_path(v)
    end

    def root_default
      File.join(home_for, ".local", "quarks")
    end

    def state_root_default
      File.join(xdg_state_home, "quarks")
    end

    def root
      v = ENV["QUARKS_ROOT"].to_s.strip
      v.empty? ? root_default : File.expand_path(v)
    end

    def state_root
      v = ENV["QUARKS_STATE_ROOT"].to_s.strip
      v.empty? ? state_root_default : File.expand_path(v)
    end

    def tmpdir
      v = ENV["QUARKS_TMPDIR"].to_s.strip
      return File.expand_path(v) unless v.empty?

      tmp = File.join(state_root, "var", "tmp", "quarks")
      FileUtils.mkdir_p(tmp)
      tmp
    rescue
      "/var/tmp/quarks"
    end

    def jobs_default
      if Etc.respond_to?(:nprocessors)
        n = Etc.nprocessors.to_i
        return n if n.positive?
      end

      if File.exist?("/proc/cpuinfo")
        n = File.read("/proc/cpuinfo").scan(/^processor\s*:/).size
        return n if n.positive?
      end

      2
    rescue
      2
    end

    def jobs
      v = ENV["QUARKS_JOBS"].to_s.strip
      return jobs_default if v.empty?

      n = v.to_i
      n.positive? ? n : jobs_default
    end

    def quiet?
      ENV["QUARKS_QUIET"].to_s == "1"
    end

    def verbose?
      return true if ENV["QUARKS_VERBOSE"].to_s == "1"
      !quiet?
    end

    def debug?
      ENV["QUARKS_DEBUG"].to_s == "1"
    end

    def warnings?
      ENV["QUARKS_WARNINGS"].to_s == "1"
    end

    def trace_system?
      ENV["QUARKS_TRACE_SYSTEM"].to_s == "1"
    end

    def allow_insecure?
      ENV["QUARKS_ALLOW_INSECURE"].to_s == "1"
    end

    def allow_duplicates?
      ENV["QUARKS_ALLOW_DUPLICATES"].to_s == "1"
    end

    def set_output_mode!(mode)
      case mode
      when :quiet
        ENV["QUARKS_QUIET"] = "1"
        ENV.delete("QUARKS_VERBOSE")
      when :verbose
        ENV["QUARKS_VERBOSE"] = "1"
        ENV.delete("QUARKS_QUIET")
      else
        raise ArgumentError, "unknown output mode: #{mode.inspect}"
      end
    end

    def enable_debug!
      ENV["QUARKS_DEBUG"] = "1"
    end

    def enable_warnings!
      ENV["QUARKS_WARNINGS"] = "1"
    end

    def bootstrap!
      FileUtils.mkdir_p(root)
      FileUtils.mkdir_p(state_root)
      FileUtils.mkdir_p(File.join(state_root, "var", "db"))
      FileUtils.mkdir_p(File.join(state_root, "var", "cache", "quarks"))
      FileUtils.mkdir_p(File.join(state_root, "var", "log", "quarks"))
      FileUtils.mkdir_p(File.join(state_root, "var", "tmp", "quarks"))
      true
    rescue
      false
    end

    def help_section
      <<~TXT

      ENVIRONMENT
      QUARKS_ROOT         Installation directory (default: ~/.local/quarks)
      QUARKS_STATE_ROOT   State/cache/log root (default: ~/.local/state/quarks)
      QUARKS_TMPDIR       Build temp dir (default: $QUARKS_STATE_ROOT/var/tmp/quarks)
      QUARKS_JOBS         Parallel build jobs (default: CPU count)
      QUARKS_VERBOSE      Enable verbose output (1/0)
      QUARKS_QUIET        Enable quiet output (1/0)
      QUARKS_DEBUG        Show debug information (1/0)
      QUARKS_WARNINGS     Show compiler warnings (1/0)
      QUARKS_TRACE_SYSTEM Trace executed system calls (1/0)
      QUARKS_NUCLEI_PATHS Additional local repo paths separated by ':'
      QUARKS_REPO_URLS    Remote repo manifest URLs separated by ':'
      QUARKS_ALLOW_INSECURE Allow checksum: skip (1/0)
      QUARKS_ALLOW_DUPLICATES Allow duplicate package definitions (1/0)
      TXT
    end

    def dump_lines
      %w[
        QUARKS_ROOT QUARKS_STATE_ROOT QUARKS_TMPDIR QUARKS_JOBS
        QUARKS_VERBOSE QUARKS_QUIET QUARKS_DEBUG QUARKS_WARNINGS
        QUARKS_TRACE_SYSTEM QUARKS_NUCLEI_PATHS QUARKS_REPO_URLS
        QUARKS_ALLOW_INSECURE QUARKS_ALLOW_DUPLICATES
      ].map do |key|
        value = ENV[key].to_s.strip
        value = "(not set)" if value.empty?
        "#{key.ljust(20)} #{value}"
      end
    end
  end
end
