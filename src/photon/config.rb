# frozen_string_literal: true

require "etc"
require "fileutils"

module Photon
  class Config
    DEFAULT_NAME = "photon.conf"

    def self.default_paths
      home = Etc.getpwnam(original_user).dir rescue Dir.home
      xdg  = ENV["XDG_CONFIG_HOME"].to_s.strip
      base = xdg.empty? ? File.join(home, ".config") : File.expand_path(xdg)

      paths = []
      paths << ENV["PHOTON_CONFIG"].to_s.strip
      paths << File.join(base, "photon", DEFAULT_NAME)
      paths << File.join(home, ".config", "photon", DEFAULT_NAME)
      paths << File.join(home, ".photon.conf")
      paths << File.join("/etc/photon", DEFAULT_NAME)
      paths.reject(&:empty?)
    end

    def self.load(path = nil)
      p = (path ? [path] : default_paths).find { |x| File.file?(x) }
      return {} unless p
      parse(File.read(p), source: p)
    end

    def self.parse(text, source: "(config)")
      out = {}

      text.each_line.with_index(1) do |line, lineno|
        raw = line.strip
        next if raw.empty? || raw.start_with?("#")

        raw = raw.split("#", 2).first.to_s.strip
        next if raw.empty?

        key, val =
          if raw.include?("=")
            raw.split("=", 2).map(&:strip)
          else
            parts = raw.split(/\s+/, 2)
            [parts[0], parts[1].to_s.strip]
          end

        next if key.to_s.empty?
        out[key] = parse_value(val)
      rescue => e
        raise "Config parse error in #{source}:#{lineno}: #{e.message}"
      end

      out
    end

    def self.original_user
      su = ENV["SUDO_USER"].to_s.strip
      return su unless su.empty?
      Etc.getlogin || ENV["USER"] || "unknown"
    end

    def self.parse_value(v)
      s = v.to_s.strip
      return "" if s.empty?

      if (s.start_with?('"') && s.end_with?('"')) || (s.start_with?("'") && s.end_with?("'"))
        return s[1..-2]
      end

      return true  if %w[1 true yes on].include?(s.downcase)
      return false if %w[0 false no off].include?(s.downcase)
      return s.to_i if s.match?(/\A-?\d+\z/)

      s
    end

    private_class_method :parse_value
  end
end
