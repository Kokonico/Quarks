# frozen_string_literal: true

require "fileutils"
require "etc"
require "shellwords"
require "quarks/security"

module Quarks
  module PathIntegration
    extend self

    SHIM_MARKER = "QUARKS-SHIM".freeze

    def shim_dir
      File.join(Database::STATE_ROOT, "var", "shims")
    end

    def setup_path!
      if Process.euid.zero? && Database.original_user != "root"
        raise "Run 'quarks setup-path' as the target user, not through sudo"
      end
      secure_shim_directory!

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
          mode = File.stat(rc_file).mode & 0o777 rescue 0o644
          updated = content.end_with?("\n") ? content : "#{content}\n"
          Quarks::Security.atomic_write(rc_file, "#{updated}\n#{snippet}", mode: mode)
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

      secure_shim_directory!

      bins = database.installed_binaries
      desired = {}

      bins.each do |name, target|
        next unless name.match?(/\A[a-zA-Z0-9+_.-]+\z/)
        shim_name = choose_shim_name(name, target)
        desired[shim_name] = target
        desired["quarks-#{name}"] ||= target
      end

      remove_stale_shims(desired.keys)
      desired.each { |shim, target| write_shim(shim, target) }
    end

    def environment_lines
      root = Database::QUARKS_ROOT
      bin_paths = %w[usr/bin usr/sbin usr/local/bin usr/local/sbin bin sbin].map { |path| File.join(root, path) }
      lib_paths = %w[usr/lib usr/lib64 usr/local/lib usr/local/lib64 lib lib64].map { |path| File.join(root, path) }
      pkg_paths = lib_paths.map { |path| File.join(path, "pkgconfig") } + [File.join(root, "usr", "share", "pkgconfig")]
      cmake_paths = [root, File.join(root, "usr"), File.join(root, "usr", "local")]
      man_paths = [File.join(root, "usr", "share", "man"), File.join(root, "usr", "local", "share", "man")]

      [
        "export QUARKS_ROOT=#{Shellwords.escape(root)}",
        "export QUARKS_STATE_ROOT=#{Shellwords.escape(Database::STATE_ROOT)}",
        "export PATH=\"$PATH\":#{Shellwords.escape(([shim_dir] + bin_paths).join(':'))}",
        "export PKG_CONFIG_PATH=#{Shellwords.escape(pkg_paths.join(':'))}:\"${PKG_CONFIG_PATH:-}\"",
        "export CMAKE_PREFIX_PATH=#{Shellwords.escape(cmake_paths.join(':'))}:\"${CMAKE_PREFIX_PATH:-}\"",
        "export MANPATH=#{Shellwords.escape(man_paths.join(':'))}:\"${MANPATH:-}\""
      ]
    end

    private

    def secure_shim_directory!
      if File.exist?(shim_dir) && !File.symlink?(shim_dir)
        stat = File.lstat(shim_dir)
        if stat.uid != Process.euid
          owner = Etc.getpwuid(stat.uid).name rescue "uid #{stat.uid}"
          user = Database.original_user
          passwd = Etc.getpwnam(user)
          group = Etc.getgrgid(passwd.gid).name
          repair = Shellwords.join(["sudo", "chown", "-R", "#{user}:#{group}", shim_dir])
          raise SecurityViolation, "Shim directory #{shim_dir} is owned by #{owner}. Repair it with: #{repair}"
        end
      end

      Security.secure_directory(shim_dir)
    end

    def path_snippet
      (["# >>> quarks setup-path >>>"] + environment_lines + ["# <<< quarks setup-path <<<", ""]).join("\n")
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
        next if Security.path_within?(dir, quarks_root)
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
        export LD_LIBRARY_PATH=#{Shellwords.escape(runtime_library_path)}:"${LD_LIBRARY_PATH:-}"
        exec #{Shellwords.escape(target)} "$@"
      SH

      Quarks::Security.atomic_write(path, script, mode: 0o755)
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

    def runtime_library_path
      %w[usr/lib usr/lib64 usr/local/lib usr/local/lib64 lib lib64]
        .map { |path| File.join(Database::QUARKS_ROOT, path) }
        .join(":")
    end
  end
end
