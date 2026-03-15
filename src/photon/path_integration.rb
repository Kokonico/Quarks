# frozen_string_literal: true

require "fileutils"

module Photon
  module PathIntegration
    extend self

    SHIM_MARKER = "PHOTON-SHIM".freeze

    def shim_dir
      File.join(Database::STATE_ROOT, "var", "shims")
    end

    def setup_path!
      FileUtils.mkdir_p(shim_dir)

      home = Database.original_user_home
      shell = ENV["SHELL"].to_s

      rc_candidates = []
      rc_candidates << File.join(home, ".zshrc") if shell.include?("zsh")
      rc_candidates << File.join(home, ".bashrc") if shell.include?("bash")
      rc_candidates << File.join(home, ".profile")
      rc_file = rc_candidates.find { |p| File.file?(p) } || rc_candidates.last

      snippet = path_snippet
      if rc_file && File.writable?(rc_file)
        content = File.read(rc_file) rescue ""
        unless content.include?("photon setup-path")
          File.open(rc_file, "a") do |f|
            f.puts
            f.puts snippet
          end
          puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Added Photon PATH snippet to #{rc_file}"
        end
      end

      unless ENV["PATH"].to_s.split(":").include?(shim_dir)
        puts "#{UI::COLORS[:yellow]}>>>#{UI::COLORS[:reset]} Note: Photon shims live at:"
        puts "  #{shim_dir}"
        puts "Make sure your shell loads Photon PATH integration (run photon setup-path once)."
      end
    end

    def sync!(database)
      return if ENV["PHOTON_DISABLE_SHIMS"] == "1"

      FileUtils.mkdir_p(shim_dir)

      bins = database.installed_binaries
      desired = {}

      bins.each do |name, target|
        shim_name = choose_shim_name(name, target)
        desired[shim_name] = target
        desired["photon-#{name}"] ||= target
      end

      remove_stale_shims(desired.keys)
      desired.each { |shim, target| write_shim(shim, target) }
    end

    private

    def path_snippet
      <<~SH
        # >>> photon setup-path >>>
        export PHOTON_ROOT="${PHOTON_ROOT:-$HOME/.local/photon}"
        export PHOTON_STATE_ROOT="${PHOTON_STATE_ROOT:-$HOME/.local/state/photon}"
        export PATH="$PATH:$PHOTON_ROOT/usr/bin:$PHOTON_ROOT/usr/sbin:$PHOTON_ROOT/usr/local/bin:$PHOTON_ROOT/usr/local/sbin:$PHOTON_STATE_ROOT/var/shims"
        # <<< photon setup-path <<<
      SH
    end

    def choose_shim_name(bin_name, target_path)
      if command_exists_outside_photon?(bin_name, target_path)
        "photon-#{bin_name}"
      else
        bin_name
      end
    end

    def command_exists_outside_photon?(bin_name, target_path)
      env_path = ENV["PATH"].to_s.split(":")
      photon_root = Database::PHOTON_ROOT.to_s

      env_path.each do |dir|
        next if dir.nil? || dir.empty?
        next if dir.start_with?(photon_root)
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
