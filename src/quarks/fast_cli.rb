# frozen_string_literal: true

require "quarks/ui"
require "quarks/version"

module Quarks
  module FastCLI
    module_function

    def safe_version_path?
      return false unless ENV["QUARKS_CONFIG"].to_s.empty?

      home = ENV["HOME"].to_s.strip
      home = Dir.home if home.empty?
      xdg = ENV["XDG_CONFIG_HOME"].to_s.strip
      xdg = File.join(home, ".config") if xdg.empty?
      candidates = [
        "/etc/quarks/quarks.conf",
        File.join(home, ".quarks.conf"),
        File.join(home, ".config", "quarks", "quarks.conf"),
        File.join(File.expand_path(xdg), "quarks", "quarks.conf")
      ]
      candidates.none? { |path| File.file?(path) }
    rescue
      false
    end

    def version
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}Quarks Package Manager#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Version #{VERSION}#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Ruby #{RUBY_VERSION}#{UI::COLORS[:reset]}"
      puts
    end
  end
end
