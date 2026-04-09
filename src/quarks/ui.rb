# frozen_string_literal: true

module Quarks
  class UI
    def self.color_enabled?
      return false if ENV["NO_COLOR"]
      return false if ENV["TERM"].to_s == "dumb"
      $stdout.tty?
    rescue
      false
    end

    def self.c(code)
      color_enabled? ? code : ""
    end

    QUARKS_THEME = ENV["QUARKS_THEME"].to_s.downcase.to_sym rescue :default

    THEMES = {
      default: {
        brand: "\e[38;5;51m",
        info: "\e[38;5;208m",
        action: "\e[38;5;141m",
        status: "\e[38;5;213m",
        highlight: "\e[38;5;228m"
      },
      midnight: {
        brand: "\e[38;5;75m",
        info: "\e[38;5;214m",
        action: "\e[38;5;147m",
        status: "\e[38;5;219m",
        highlight: "\e[38;5;230m"
      },
      forest: {
        brand: "\e[38;5;28m",
        info: "\e[38;5;172m",
        action: "\e[38;5;35m",
        status: "\e[38;5;78m",
        highlight: "\e[38;5;192m"
      },
      ocean: {
        brand: "\e[38;5;39m",
        info: "\e[38;5;208m",
        action: "\e[38;5;45m",
        status: "\e[38;5;201m",
        highlight: "\e[38;5;230m"
      }
    }.freeze

    def self.current_theme
      THEMES[QUARKS_THEME] || THEMES[:default]
    end

    COLORS = {
      reset: c("\e[0m"),
      bold: c("\e[1m"),
      dim: c("\e[2m"),
      red: c("\e[31m"),
      green: c("\e[32m"),
      yellow: c("\e[33m"),
      blue: c("\e[34m"),
      magenta: c("\e[35m"),
      cyan: c("\e[36m"),
      white: c("\e[37m"),
      gray: c("\e[90m"),
      bright_red: c("\e[91m"),
      bright_green: c("\e[92m"),
      bright_yellow: c("\e[93m"),
      bright_blue: c("\e[94m"),
      bright_cyan: c("\e[96m"),
      bright_white: c("\e[97m"),
      brand: c(current_theme[:brand]),
      info: c(current_theme[:info]),
      action: c(current_theme[:action]),
      status: c(current_theme[:status]),
      highlight: c(current_theme[:highlight])
    }.freeze

    class << self
      def success(message)
        puts "#{COLORS[:green]}[ok]#{COLORS[:reset]} #{message}"
      end

      def error(message)
        $stderr.puts "#{COLORS[:red]}[error]#{COLORS[:reset]} #{message}"
      end

      def warning(message)
        puts "#{COLORS[:yellow]}[warn]#{COLORS[:reset]} #{message}"
      end

      def info(message)
        puts "#{COLORS[:blue]}[info]#{COLORS[:reset]} #{message}"
      end

      def brand(msg)
        puts "#{COLORS[:brand]}#{msg}#{COLORS[:reset]}"
      end

      def status(msg)
        puts "#{COLORS[:status]}#{msg}#{COLORS[:reset]}"
      end

      def highlight(msg)
        puts "#{COLORS[:highlight]}#{msg}#{COLORS[:reset]}"
      end

      def hr(char = "-", width: 70)
        puts "#{COLORS[:dim]}#{char * width}#{COLORS[:reset]}"
      end

      def format_bytes(bytes)
        units = %w[B KB MB GB TB]
        b = bytes.to_i
        return "0 B" if b <= 0

        exp = (Math.log(b) / Math.log(1024)).floor
        exp = [exp, units.length - 1].min

        size = (b.to_f / (1024**exp)).round(2)
        "#{size} #{units[exp]}"
      end

      def pretty_build_line(line, debug: false)
        s = line.to_s.chomp
        return if s.empty?

        if s =~ /error:/i || s =~ /\bfatal error:/i
          puts "#{COLORS[:red]}!!! #{s}#{COLORS[:reset]}"
          return
        end

        if s =~ /warning:/i
          if ENV["QUARKS_WARNINGS"] == "1"
            puts "#{COLORS[:yellow]}! #{s}#{COLORS[:reset]}"
          end
          return
        end

        if s =~ /^make\[\d+\]: Entering directory/
          dir = s[/Entering directory '([^']+)'/, 1]
          puts "#{COLORS[:brand]}>>> #{COLORS[:reset]}Entering #{File.basename(dir)}" if dir
          return
        end

        return if s =~ /^make\[\d+\]: Leaving directory/

        if s =~ /^-- / || s =~ /^checking / || s =~ /^Configuring /i || s =~ /^Configuring done/i || s =~ /^Generating done/i
          puts "#{COLORS[:cyan]}:: #{COLORS[:reset]}#{s}"
          return
        end

        if s =~ /^CMake (Warning|Error)/i
          puts "#{COLORS[:yellow]}! #{s}#{COLORS[:reset]}"
          return
        end

        if s =~ /^ninja/i
          if s =~ /\s-C\s+(\S+)/
            dir = Regexp.last_match(1)
            puts "#{COLORS[:action]}>>> #{COLORS[:reset]}Building in #{COLORS[:action]}#{File.basename(dir)}#{COLORS[:reset]}"
          elsif s =~ /^\[\s*(\d+)\/(\d+)\]/
            current = Regexp.last_match(1)
            total = Regexp.last_match(2)
            target = s.split.last
            puts "#{COLORS[:action]}>>> #{COLORS[:reset]}[#{current}/#{total}] #{COLORS[:action]}#{File.basename(target)}#{COLORS[:reset]}"
          end
          return
        end

        if s.strip =~ /^(gcc|g\+\+|cc|clang|clang\+\+|c\+\+)\s/
          if s =~ /\s-o\s+(\S+)/
            out = Regexp.last_match(1)
            base = File.basename(out)
            if base.end_with?(".o", ".obj")
              puts "#{COLORS[:brand]}>>> #{COLORS[:reset]}Compiling #{COLORS[:brand]}#{base}#{COLORS[:reset]}"
            else
              puts "#{COLORS[:info]}>>> #{COLORS[:reset]}Linking  #{COLORS[:info]}#{base}#{COLORS[:reset]}"
            end
          else
            puts "#{COLORS[:brand]}>>> #{COLORS[:reset]}Compiling"
          end
          return
        end

        if s =~ /^\[\s*\d+%\]\s+Building/i
          target = s.split.last
          puts "#{COLORS[:brand]}>>> #{COLORS[:reset]}Building #{COLORS[:brand]}#{File.basename(target)}#{COLORS[:reset]}"
          return
        end

        if s =~ /^\[\s*\d+%\]\s+Linking/i
          target = s.split.last
          puts "#{COLORS[:info]}>>> #{COLORS[:reset]}Linking  #{COLORS[:info]}#{File.basename(target)}#{COLORS[:reset]}"
          return
        end

        puts "#{COLORS[:dim]}#{s}#{COLORS[:reset]}" if debug
      end

      def banner
        theme_name = QUARKS_THEME.to_s.capitalize
        puts
        puts "#{COLORS[:brand]}    Quarks Package Manager#{COLORS[:reset]}"
        puts "#{COLORS[:dim]}    Theme: #{theme_name}#{COLORS[:reset]}" unless QUARKS_THEME == :default
        puts
      end

      def progress_bar(current, total, width: 40, prefix: "")
        percent = total.positive? ? (current.to_f / total * 100).round : 0
        filled = (width * current / total).to_i
        bar = "#" * filled + "-" * (width - filled)
        prefix_str = prefix.empty? ? "" : "#{prefix} "
        puts "#{prefix_str}[#{COLORS[:brand]}#{bar}#{COLORS[:reset]}] #{percent}%"
      end

      def list_themes
        puts "\nAvailable themes:"
        THEMES.each_key do |theme|
          selected = theme == QUARKS_THEME ? " #{COLORS[:green]}[*]#{COLORS[:reset]}" : ""
          puts "  #{theme.to_s.capitalize.ljust(12)}#{selected}"
        end
        puts
      end
    end
  end
end
