# frozen_string_literal: true

require "fileutils"
require "find"
require "shellwords"

require "photon/system_integration"

module Photon
  class Installer
    class InstallError < StandardError; end
    class RollbackError < StandardError; end
    class PostInstallError < StandardError; end

    def initialize(package, database, options: {})
      @package = package
      @database = database
      @options = options || {}
      @installed_files = []
      @post_install_actions = []
      @rollback_stack = []
    end

    def install(dest_dir)
      raise InstallError, "Staging directory does not exist: #{dest_dir}" unless Dir.exist?(dest_dir)

      install_root = Database::PHOTON_ROOT
      FileUtils.mkdir_p(install_root) unless Dir.exist?(install_root)

      validate_staging_directory(dest_dir)

      @installed_files = collect_image_files(dest_dir)

      if @installed_files.empty?
        raise InstallError, "Install phase produced no files in #{dest_dir}"
      end

      collisions = @database.find_collisions(@installed_files, exclude_package: @package.name)
      if collisions.any?
        preview = collisions.first(12).map { |c| "  #{c[:path]} (owned by #{c[:owner]})" }.join("\n")
        raise InstallError, <<~MSG.strip
          Cannot install #{@package.atom}: file ownership collision detected.

          #{preview}

          Resolve the conflicting package(s) first.
        MSG
      end

      sudo_needed = !writable_dir?(install_root)
      start_time = Time.now

      perform_install(dest_dir, install_root, sudo: sudo_needed)
      install_time = Time.now - start_time

      begin
        ok = @database.add_package(@package, files: @installed_files, install_time: install_time)
        raise InstallError, "Failed to register package in database" unless ok

        perform_post_install_tasks(install_root, sudo: sudo_needed)

      rescue => e
        perform_rollback(install_root, sudo: sudo_needed, error: e)
        raise e
      end

      @installed_files
    end

    def uninstall
      pkg_info = @database.get_package(@package.name)
      raise InstallError, "Package not in database: #{@package.name}" unless pkg_info

      install_root = Database::PHOTON_ROOT
      sudo_needed = !writable_dir?(install_root)
      files = Array(pkg_info[:files])
      removed = 0
      failed_removals = []

      perform_pre_uninstall_tasks(pkg_info, install_root, sudo: sudo_needed)

      files.sort_by { |path| -path.length }.each do |rel|
        target = File.join(install_root, rel.sub(%r{^/+}, ""))
        next unless File.exist?(target) || File.symlink?(target)

        if sudo_needed
          success = system("sudo", "rm", "-f", target)
          if success
            removed += 1
          else
            failed_removals << target
          end
        else
          begin
            FileUtils.rm_f(target)
            removed += 1
          rescue => e
            failed_removals << target
          end
        end
      end

      prune_empty_dirs(files, install_root, sudo: sudo_needed)

      if failed_removals.any?
        warn "[photon] Warning: Failed to remove #{failed_removals.length} file(s)"
      end

      @database.remove_package(@package.name)

      perform_post_uninstall_tasks(install_root)

      removed
    end

    private

    def validate_staging_directory(dest_dir)
      symlinks = []
      Find.find(dest_dir) do |path|
        next unless File.symlink?(path)
        symlinks << path if path != dest_dir
      end

      return if symlinks.empty?

      symlinks.each do |link|
        target = File.readlink(link)
        next unless target.start_with?("/")

        abs_link = File.expand_path(link)
        abs_target = File.expand_path(target, File.dirname(link))

        unless abs_target.start_with?(dest_dir) || abs_target.start_with?(Database::PHOTON_ROOT)
          raise InstallError, "Dangerous absolute symlink detected: #{link} -> #{target}"
        end
      end
    end

    def perform_install(dest_dir, install_root, sudo: false)
      copy_image_tree(dest_dir, install_root, sudo: sudo)
      @rollback_stack << [:copy, dest_dir, install_root]
    end

    def perform_rollback(install_root, sudo: false, error: nil)
      puts "[photon] Initiating rollback due to: #{error&.message || 'unknown error'}"
      rolled_back = 0
      failed = []

      @installed_files.sort_by { |path| -path.length }.each do |rel|
        target = File.join(install_root, rel)
        begin
          if sudo
            system("sudo", "rm", "-f", target)
          else
            FileUtils.rm_f(target)
          end
          rolled_back += 1
        rescue => e
          failed << { path: target, error: e.message }
        end
      end

      prune_empty_dirs(@installed_files, install_root, sudo: sudo)

      puts "[photon] Rollback complete: #{rolled_back} file(s) removed"
      if failed.any?
        puts "[photon] Warning: #{failed.length} file(s) could not be removed"
      end
    end

    def perform_post_install_tasks(install_root, sudo: false)
      @post_install_actions = SystemIntegration.install_handlers(@package, install_root, install_root)

      needs_ldconfig = @post_install_actions.any? { |a| a[:type] == :ldconfig }
      if needs_ldconfig
        LdconfigManager.cache_libraries(install_root)
        unless LdconfigManager.update_ldconfig(dry_run: @options[:pretend])
          warn "[photon] Warning: ldconfig update failed"
        end
      end

      desktop_files = @post_install_actions.select { |a| a[:type] == :desktop_file }
      if desktop_files.any?
        DesktopDatabaseManager.update_desktop_database(install_root, dry_run: @options[:pretend])
      end

      info_actions = @post_install_actions.select { |a| a[:type] == :info_pages }
      if info_actions.any?
        update_info_database(install_root, dry_run: @options[:pretend])
      end

      mime_needed = @post_install_actions.any? { |a| a[:type] == :mimedb }
      if mime_needed
        MimedbManager.update_mime_database(install_root, dry_run: @options[:pretend])
      end

      gtk_icons = @post_install_actions.any? { |a| a[:type] == :gtk_icon_cache }
      if gtk_icons
        GTKIconCacheManager.update_icon_cache(install_root, dry_run: @options[:pretend])
      end
    end

    def perform_pre_uninstall_tasks(pkg_info, install_root, sudo: false)
      alt_name = @package.name.to_s
      if UpdateAlternativesManager.query(alt_name)
        UpdateAlternativesManager.unregister(alt_name, install_root, dry_run: @options[:pretend])
      end
    end

    def perform_post_uninstall_tasks(install_root)
      LdconfigManager.update_ldconfig(dry_run: @options[:pretend])
      DesktopDatabaseManager.update_desktop_database(install_root, dry_run: @options[:pretend])
    end

    def collect_image_files(dest_dir)
      files = []
      Find.find(dest_dir) do |path|
        next if path == dest_dir
        next if File.directory?(path)

        rel = path.sub(dest_dir, "").sub(%r{^/+}, "")
        next if rel.empty?
        files << rel
      end
      files.sort.uniq
    end

    def copy_image_tree(src_dir, install_root, sudo: false)
      cmd = ["cp", "-a", "#{src_dir}/.", install_root]
      ok = sudo ? system("sudo", *cmd) : system(*cmd)
      return if ok

      raise InstallError, <<~MSG.strip
        Failed to copy staged files into install root:

          #{install_root}

        Fix permissions or use a writable PHOTON_ROOT.
      MSG
    end

    def rollback_files(files, install_root, sudo: false)
      files.sort_by { |path| -path.length }.each do |rel|
        target = File.join(install_root, rel)
        begin
          if sudo
            system("sudo", "rm", "-f", target)
          else
            FileUtils.rm_f(target)
          end
        rescue
          nil
        end
      end

      prune_empty_dirs(files, install_root, sudo: sudo)
    end

    def prune_empty_dirs(files, install_root, sudo: false)
      dirs = files.map { |path| File.dirname(path.sub(%r{^/+}, "")) }.uniq
      dirs.sort_by! { |dir| -dir.length }

      dirs.each do |dir|
        next if dir == "." || dir.empty?

        abs = File.join(install_root, dir)
        next unless Dir.exist?(abs)

        begin
          if sudo
            system("sudo", "rmdir", abs)
          else
            Dir.rmdir(abs)
          end
        rescue Errno::ENOTEMPTY, Errno::ENOENT
          nil
        rescue
          nil
        end
      end
    end

    def writable_dir?(path)
      FileUtils.mkdir_p(path) unless Dir.exist?(path)
      test = File.join(path, ".photon_write_test_#{Process.pid}")
      File.write(test, "ok")
      File.delete(test)
      true
    rescue
      false
    end

    def update_info_database(install_root, dry_run: false)
      return true unless command_exists?("install-info")

      info_files = find_info_files(install_root)
      info_files.each do |file|
        if dry_run
          puts "[photon] Would run: install-info #{file}"
        else
          system("install-info #{Shellwords.escape(file)} /usr/share/info/dir 2>/dev/null")
        end
      end

      true
    rescue => e
      warn "[photon] Warning: info database update failed: #{e.message}"
      false
    end

    def find_info_files(root)
      files = []
      patterns = [
        File.join(root, "usr", "share", "info", "*.info*"),
        File.join(root, "usr", "local", "share", "info", "*.info*")
      ]

      patterns.each do |pattern|
        Dir.glob(pattern).each do |file|
          files << file if File.file?(file)
        end
      end

      files
    end

    def command_exists?(name)
      system("command -v #{Shellwords.escape(name)} >/dev/null 2>&1")
    end
  end
end
