# frozen_string_literal: true

require "etc"

module Quarks
  class Config
    class Error < ArgumentError; end

    DEFAULT_NAME = "quarks.conf"
    MAX_CONFIG_BYTES = 1024 * 1024
    BOOLEAN_KEYS = {
      "quiet" => "QUARKS_QUIET",
      "verbose" => "QUARKS_VERBOSE",
      "debug" => "QUARKS_DEBUG",
      "warnings" => "QUARKS_WARNINGS",
      "build_network" => "QUARKS_BUILD_NETWORK",
      "allow_private_networks" => "QUARKS_ALLOW_PRIVATE_NETWORKS",
      "allow_insecure_sources" => "QUARKS_ALLOW_INSECURE_SOURCES",
      "allow_insecure_repositories" => "QUARKS_ALLOW_INSECURE_REPOS",
      "allow_unsigned_repositories" => "QUARKS_ALLOW_UNSIGNED_REPOS"
    }.freeze
    PATH_KEYS = {
      "root" => "QUARKS_ROOT",
      "state_root" => "QUARKS_STATE_ROOT",
      "tmpdir" => "QUARKS_TMPDIR"
    }.freeze
    INTEGER_KEYS = {
      "jobs" => ["QUARKS_JOBS", 1, 1024],
      "size_probe_ms" => ["QUARKS_SIZE_PROBE_MS", 0, 5000],
      "max_source_bytes" => ["QUARKS_MAX_SOURCE_BYTES", 1, 1 << 50],
      "max_extracted_bytes" => ["QUARKS_MAX_EXTRACTED_BYTES", 1, 1 << 50],
      "max_extracted_files" => ["QUARKS_MAX_EXTRACTED_FILES", 1, 10_000_000],
      "max_log_bytes" => ["QUARKS_MAX_LOG_BYTES", 1, 1 << 40]
    }.freeze
    STRING_KEYS = {
      "use" => "QUARKS_USE",
      "nuclei_paths" => "QUARKS_NUCLEI_PATHS",
      "repo_urls" => "QUARKS_REPO_URLS"
    }.freeze
    KNOWN_KEYS = (BOOLEAN_KEYS.keys + PATH_KEYS.keys + INTEGER_KEYS.keys + STRING_KEYS.keys + ["sandbox"]).freeze

    class << self
      attr_reader :loaded_paths

      def default_paths
        home = user_home
        xdg = ENV["XDG_CONFIG_HOME"].to_s.strip
        xdg = File.join(home, ".config") if xdg.empty?

        paths = [
          File.join("/etc/quarks", DEFAULT_NAME),
          File.join(home, ".quarks.conf"),
          File.join(home, ".config", "quarks", DEFAULT_NAME),
          File.join(File.expand_path(xdg), "quarks", DEFAULT_NAME)
        ]
        explicit = ENV["QUARKS_CONFIG"].to_s.strip
        paths << File.expand_path(explicit) unless explicit.empty?
        paths.uniq
      end

      def load(path = nil)
        paths = path ? [File.expand_path(path)] : default_paths
        explicit = path || ENV["QUARKS_CONFIG"].to_s.strip
        unless explicit.to_s.empty?
          explicit_path = File.expand_path(explicit)
          raise Error, "Explicit configuration file does not exist: #{explicit_path}" unless File.file?(explicit_path)
        end
        @loaded_paths = paths.select { |candidate| File.file?(candidate) }
        @loaded_paths.each_with_object({}) do |candidate, config|
          stat = File.stat(candidate)
          mode = stat.mode
          if (mode & 0o022).positive?
            raise Error, "Refusing group/world-writable configuration file: #{candidate}"
          end
          if stat.size > MAX_CONFIG_BYTES
            raise Error, "Configuration file exceeds #{MAX_CONFIG_BYTES} bytes: #{candidate}"
          end
          config.merge!(parse(File.read(candidate), source: candidate))
        end.tap { |config| validate!(config) }
      end

      def apply_env!(path = nil)
        config = load(path)
        config.each do |key, value|
          env_name, formatted = env_value(key, value)
          ENV[env_name] = formatted if ENV[env_name].to_s.empty?
        end
        config.freeze
      end

      def parse(text, source: "(config)")
        out = {}
        text.each_line.with_index(1) do |line, lineno|
          raw = strip_inline_comment(line).strip
          next if raw.empty?

          key, value = if raw.include?("=")
                         raw.split("=", 2).map(&:strip)
                       else
                         raw.split(/\s+/, 2)
                       end
          raise Error, "Config parse error in #{source}:#{lineno}: missing value" if value.to_s.strip.empty?
          raise Error, "Config parse error in #{source}:#{lineno}: duplicate key #{key}" if out.key?(key)

          out[key] = parse_value(value)
        rescue Error
          raise
        rescue => e
          raise Error, "Config parse error in #{source}:#{lineno}: #{e.message}"
        end
        out
      end

      def original_user
        sudo_user = ENV["SUDO_USER"].to_s.strip
        return sudo_user if Process.euid.zero? && !sudo_user.empty?
        Etc.getlogin || ENV["USER"] || Etc.getpwuid(Process.uid).name
      rescue
        "unknown"
      end

      private

      def user_home
        Etc.getpwnam(original_user).dir
      rescue
        Dir.home
      end

      def validate!(config)
        unknown = config.keys - KNOWN_KEYS
        raise Error, "Unknown configuration key(s): #{unknown.join(', ')}" unless unknown.empty?
        config.each { |key, value| env_value(key, value) }
        true
      end

      def env_value(key, value)
        if key == "sandbox"
          raise Error, "sandbox must be true or false" unless value == true || value == false
          return ["QUARKS_NO_SANDBOX", value ? "0" : "1"]
        end

        if BOOLEAN_KEYS.key?(key)
          raise Error, "#{key} must be true or false" unless value == true || value == false
          return [BOOLEAN_KEYS.fetch(key), value ? "1" : "0"]
        end

        if PATH_KEYS.key?(key)
          raw = value.to_s.strip
          raise Error, "#{key} must not be empty" if raw.empty?
          return [PATH_KEYS.fetch(key), File.expand_path(raw)]
        end

        if INTEGER_KEYS.key?(key)
          env_name, minimum, maximum = INTEGER_KEYS.fetch(key)
          integer = Integer(value, exception: false)
          raise Error, "#{key} must be an integer between #{minimum} and #{maximum}" unless integer&.between?(minimum, maximum)
          return [env_name, integer.to_s]
        end

        if STRING_KEYS.key?(key)
          raw = value.to_s.strip
          raise Error, "#{key} must not contain a NUL or newline" if raw.include?("\0") || raw.match?(/[\r\n]/)
          return [STRING_KEYS.fetch(key), raw]
        end

        raise Error, "Unknown configuration key: #{key}"
      end

      def parse_value(value)
        raw = value.to_s.strip
        if raw.start_with?("\"") || raw.start_with?("'")
          quote = raw[0]
          raise Error, "unterminated quoted value" unless raw.end_with?(quote) && raw.length >= 2
          return raw[1...-1]
        end

        lowered = raw.downcase
        return true if %w[1 true yes on].include?(lowered)
        return false if %w[0 false no off].include?(lowered)
        return raw.to_i if raw.match?(/\A-?\d+\z/)
        raw
      end

      def strip_inline_comment(line)
        quote = nil
        escaped = false
        line.each_char.with_index do |char, index|
          if escaped
            escaped = false
          elsif char == "\\" && quote == '"'
            escaped = true
          elsif quote
            quote = nil if char == quote
          elsif char == '"' || char == "'"
            quote = char
          elsif char == "#"
            return line[0...index]
          end
        end
        line
      end
    end
  end
end
