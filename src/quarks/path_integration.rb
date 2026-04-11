# frozen_string_literal: true

require "fileutils"

module Quarks
  module PathIntegration
    extend self

    SHIM_MARKER = "QUARKS-SHIM".freeze

    def shim_dir
      File.join(Database::STATE_ROOT, "var", "shims")
    end

    def setup_path!
      FileUtils.mkdir_p(shim_dir)

      home = Database.original_user_home

      rc_candidates = []
      # TODO add commands on all available shells, not just active shell
      # zsh
      rc_candidates << File.join(home, ".zshrc") if File.exist? File.join(home, ".zshrc")
      # bash
      rc_candidates << File.join(home, ".bashrc") if File.exist? File.join(home, ".bashrc")
      rc_candidates << File.join(home, ".profile")
      rc_file = rc_candidates.find { |p| File.file?(p) } || rc_candidates.last

      snippet = path_snippet
      if rc_file && File.writable?(rc_file)
        content = File.read(rc_file) rescue ""
        unless content.include?("quarks setup-path")
          File.open(rc_file, "a") do |f|
            f.puts
            f.puts snippet
          end
          puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Added Quarks PATH snippet to #{rc_file}"
        end
      end

      unless ENV["PATH"].to_s.split(":").include?(shim_dir)
        puts "#{UI::COLORS[:yellow]}>>>#{UI::COLORS[:reset]} Note: Quarks shims live at:"
        puts "  #{shim_dir}"
        puts "Make sure your shell loads Quarks PATH integration (run quarks setup-path once)."
      end
    end

    def sync!(database)
      return if ENV["QUARKS_DISABLE_SHIMS"] == "1"

      FileUtils.mkdir_p(shim_dir)

      bins = database.installed_binaries
      desired = {}

      bins.each do |name, target|
        shim_name = choose_shim_name(name, target)
        desired[shim_name] = target
        desired["quarks-#{name}"] ||= target
      end

      remove_stale_shims(desired.keys)
      desired.each { |shim, target| write_shim(shim, target) }
    end

    private

    def path_snippet
      <<~SH
        # >>> quarks setup-path >>>
        export QUARKS_ROOT="${QUARKS_ROOT:-$HOME/.local/quarks}"
        export QUARKS_STATE_ROOT="${QUARKS_STATE_ROOT:-$HOME/.local/state/quarks}"
        export PATH="$PATH:$QUARKS_ROOT/usr/bin:$QUARKS_ROOT/usr/sbin:$QUARKS_ROOT/usr/local/bin:$QUARKS_ROOT/usr/local/sbin:$QUARKS_STATE_ROOT/var/shims"
        # <<< quarks setup-path <<<
      SH
    end

    def choose_shim_name(bin_name, target_path)
      if command_exists_outside_quarks?(bin_name, target_path)
        "quarks-#{bin_name}"
      else
        bin_name
      end
    end

    def command_exists_outside_quarks?(bin_name, target_path)
      env_path = ENV["PATH"].to_s.split(":")
      quarks_root = Database::QUARKS_ROOT.to_s

      env_path.each do |dir|
        next if dir.nil? || dir.empty?
        next if dir.start_with?(quarks_root)
        next if dir == shim_dir

        cand = File.join(dir, bin_name)
        next unless File.file?(cand)
        next unless File.executable?(cand)

        return true unless File.expand_path(cand) == File.expand_path(target_path)
      end

      false
    rescue
      false
    end

    def write_shim(name, target)
      path = File.join(shim_dir, name)
      if File.exist?(path) && !(File.read(path) rescue "").include?(SHIM_MARKER)
        return
      end

      script = <<~SH
        #!/bin/sh
        # #{SHIM_MARKER}
        exec "#{target}" "$@"
      SH

      File.write(path, script)
      FileUtils.chmod(0o755, path)
    rescue
      nil
    end

    def remove_stale_shims(keep_names)
      Dir.glob(File.join(shim_dir, "*")).each do |p|
        next unless File.file?(p)
        next unless File.executable?(p)

        content = File.read(p) rescue ""
        next unless content.include?(SHIM_MARKER)

        base = File.basename(p)
        next if keep_names.include?(base)

        FileUtils.rm_f(p)
      end
    rescue
      nil
    end
  end
end
