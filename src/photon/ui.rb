# frozen_string_literal: true

module Photon
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

    COLORS = {
      reset: c("\e[0m"),
      bold: c("\e[1m"),
      dim: c("\e[2m"),
      red: c("\e[31m"),
      green: c("\e[32m"),
      yellow: c("\e[33m"),
      blue: c("\e[34m"),
      cyan: c("\e[36m"),
      gray: c("\e[90m"),
      bright_cyan: c("\e[96m"),
      bright_green: c("\e[92m"),
      bright_blue: c("\e[94m")
    }.freeze

    class << self
      def success(message)
        puts "#{COLORS[:green]}✓#{COLORS[:reset]} #{message}"
      end

      def error(message)
        $stderr.puts "#{COLORS[:red]}✗ Error:#{COLORS[:reset]} #{message}"
      end

      def warning(message)
        puts "#{COLORS[:yellow]}⚠ Warning:#{COLORS[:reset]} #{message}"
      end

      def info(message)
        puts "#{COLORS[:blue]}ℹ#{COLORS[:reset]} #{message}"
      end

      def hr(char = "─", width: 70)
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
          puts "#{COLORS[:red]} !!! #{s}#{COLORS[:reset]}"
          return
        end

        if s =~ /warning:/i
          if ENV["PHOTON_WARNINGS"] == "1"
            puts "#{COLORS[:yellow]} ! #{s}#{COLORS[:reset]}"
          end
          return
        end

        if s =~ /^make\[\d+\]: Entering directory/
          dir = s[/Entering directory '([^']+)'/, 1]
          puts "#{COLORS[:blue]} >>>#{COLORS[:reset]} Entering #{File.basename(dir)}" if dir
          return
        end

        return if s =~ /^make\[\d+\]: Leaving directory/

        if s =~ /^-- / || s =~ /^checking / || s =~ /^Configuring /i || s =~ /^Configuring done/i || s =~ /^Generating done/i
          puts "#{COLORS[:cyan]} ::#{COLORS[:reset]} #{s}"
          return
        end

        if s =~ /^CMake (Warning|Error)/i
          puts "#{COLORS[:yellow]} ! #{s}#{COLORS[:reset]}"
          return
        end

        if s.strip =~ /^(gcc|g\+\+|cc|clang|clang\+\+|c\+\+)\s/
          if s =~ /\s-o\s+(\S+)/
            out = Regexp.last_match(1)
            base = File.basename(out)
            if base.end_with?(".o", ".obj")
              puts "#{COLORS[:green]} *#{COLORS[:reset]} Building #{COLORS[:bright_green]}#{base}#{COLORS[:reset]}"
            else
              puts "#{COLORS[:yellow]} *#{COLORS[:reset]} Linking  #{COLORS[:yellow]}#{base}#{COLORS[:reset]}"
            end
          else
            puts "#{COLORS[:green]} *#{COLORS[:reset]} Building"
          end
          return
        end

        if s =~ /^(CC|CXX|AR|RANLIB)\s+(.+)$/
          puts "#{COLORS[:green]} *#{COLORS[:reset]} Building #{File.basename(Regexp.last_match(2).strip)}"
          return
        end

        if s =~ /^(LD)\s+(.+)$/
          puts "#{COLORS[:yellow]} *#{COLORS[:reset]} Linking  #{File.basename(Regexp.last_match(2).strip)}"
          return
        end

        if s =~ /^libtool:\s+link:/i
          puts "#{COLORS[:yellow]} *#{COLORS[:reset]} Linking  #{s.sub(/^libtool:\s+link:\s*/i, '').strip}"
          return
        end

        if s =~ /^\[\s*\d+%\]\s+Building/i
          target = s.split.last
          puts "#{COLORS[:green]} *#{COLORS[:reset]} Building #{COLORS[:bright_green]}#{File.basename(target)}#{COLORS[:reset]}"
          return
        end

        if s =~ /^\[\s*\d+%\]\s+Linking/i
          target = s.split.last
          puts "#{COLORS[:yellow]} *#{COLORS[:reset]} Linking  #{COLORS[:yellow]}#{File.basename(target)}#{COLORS[:reset]}"
          return
        end

        puts "#{COLORS[:dim]}#{s}#{COLORS[:reset]}" if debug
      end
    end
  end
end
