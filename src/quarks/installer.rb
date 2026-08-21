# frozen_string_literal: true

require "fileutils"
require "find"
require "shellwords"
require "tmpdir"
require "digest"

require "quarks/operation_lock"
require "quarks/system_integration"

module Quarks
  class Installer
    class InstallError < StandardError; end
    class RollbackError < StandardError; end
    class PostInstallError < StandardError; end
    PROCESS_ENV = { "PATH" => "/usr/bin:/usr/sbin:/bin:/sbin", "LANG" => "C", "LC_ALL" => "C" }.freeze

    def initialize(package, database, options: {})
      @package = package
      @database = database
      @options = options || {}
      @installed_files = []
      @post_install_actions = []
      @rollback_stack = []
    end

    def install(dest_dir)
      OperationLock.synchronize("filesystem-merge") { install_unlocked(dest_dir) }
    end

    def uninstall
      OperationLock.synchronize("filesystem-merge") { uninstall_unlocked }
    end

    private

    def install_unlocked(dest_dir)
      raise InstallError, "Staging directory does not exist: #{dest_dir}" unless Dir.exist?(dest_dir)

      install_root = Database::QUARKS_ROOT
      ensure_install_root!(install_root)

      validate_staging_directory(dest_dir)

      @file_manifest = collect_image_manifest(dest_dir)
      @installed_files = @file_manifest.map { |entry| entry[:path] }

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

      validate_destination_tree!(dest_dir, install_root)

      sudo_needed = !writable_dir?(install_root)
      raise InstallError, "Install root is not writable and trusted system sudo is unavailable" if sudo_needed && !sudo_path
      start_time = Time.now
      previous = @database.get_package(@package.name)
      backup_paths = (@installed_files + Array(previous&.dig(:files))).uniq
      rollback_dir = create_rollback_dir
      backed_up = []

      begin
        backed_up = backup_existing_paths(backup_paths, install_root, rollback_dir, sudo: sudo_needed)
        perform_install(dest_dir, install_root, sudo: sudo_needed)
        verify_installed_manifest!(install_root)
        install_time = Time.now - start_time
        ok = @database.add_package(
          @package,
          files: @file_manifest,
          install_time: install_time,
          world: @options[:world] && !@options[:oneshot]
        )
        raise InstallError, "Failed to register package in database" unless ok

        perform_post_install_tasks(dest_dir, install_root, sudo: sudo_needed)
        remove_obsolete_upgrade_files(previous, install_root, sudo: sudo_needed)

      rescue => e
        rollback_failures = perform_rollback(
          install_root,
          rollback_dir: rollback_dir,
          backed_up: backed_up,
          sudo: sudo_needed,
          error: e
        )
        database_error = nil
        database_restored = begin
          if previous
            @database.restore_package(previous)
          elsif @database.get_package(@package.name)
            @database.remove_package(@package.name)
          else
            true
          end
        rescue => database_exception
          database_error = database_exception.message
          false
        end
        unless rollback_failures.empty? && database_restored
          details = rollback_failures.first(5).map { |failure| "#{failure[:path]}: #{failure[:error]}" }.join("; ")
          details = "database state could not be restored#{": #{database_error}" if database_error}" unless database_restored
          raise RollbackError, "Install failed (#{e.message}) and rollback was incomplete: #{details}"
        end
        raise
      ensure
        cleanup_rollback_dir(rollback_dir, sudo: sudo_needed)
      end

      @installed_files
    end

    def uninstall_unlocked
      pkg_info = @database.get_package(@package.name)
      raise InstallError, "Package not in database: #{@package.name}" unless pkg_info

      install_root = Database::QUARKS_ROOT
      sudo_needed = !writable_dir?(install_root)
      raise InstallError, "Install root is not writable and trusted system sudo is unavailable" if sudo_needed && !sudo_path
      files = Array(pkg_info[:files])
      manifest_by_path = Array(pkg_info[:file_manifest]).to_h { |entry| [entry[:path], entry] }
      removed = 0
      preserved = []
      failed_removals = []
      rollback_dir = create_rollback_dir
      backed_up = []

      begin
        backed_up = backup_existing_paths(files, install_root, rollback_dir, sudo: sudo_needed)
        perform_pre_uninstall_tasks(pkg_info, install_root, sudo: sudo_needed)

        files.sort_by { |path| -path.length }.each do |rel|
          target = File.join(install_root, rel.sub(%r{^/+}, ""))
          next unless File.exist?(target) || File.symlink?(target)
          if protected_config_path?(rel) && file_changed?(target, manifest_by_path[rel]) && !@options[:force]
            preserved << rel
            next
          end

          if sudo_needed
            success = run_process(sudo_path, "/bin/rm", "-f", "--", target)
            if success
              removed += 1
            else
              failed_removals << target
            end
          else
            begin
              FileUtils.rm_f(target)
              removed += 1
            rescue
              failed_removals << target
            end
          end
        end

        prune_empty_dirs(files, install_root, sudo: sudo_needed)

        if failed_removals.any?
          raise InstallError, "Failed to remove #{failed_removals.length} file(s); package registration was retained"
        end

        unless @database.remove_package(@package.name)
          raise InstallError, "Files were removed but package registration could not be removed"
        end

        perform_post_uninstall_tasks(install_root, sudo: sudo_needed)
      rescue => e
        rollback_failures = perform_rollback(
          install_root,
          rollback_dir: rollback_dir,
          backed_up: backed_up,
          sudo: sudo_needed,
          error: e
        )
        database_error = nil
        database_restored = begin
          @database.get_package(@package.name) ? true : @database.restore_package(pkg_info)
        rescue => database_exception
          database_error = database_exception.message
          false
        end
        unless rollback_failures.empty? && database_restored
          details = rollback_failures.first(5).map { |failure| "#{failure[:path]}: #{failure[:error]}" }.join("; ")
          details = "database state could not be restored#{": #{database_error}" if database_error}" unless database_restored
          raise RollbackError, "Uninstall failed (#{e.message}) and rollback was incomplete: #{details}"
        end
        raise
      ensure
        cleanup_rollback_dir(rollback_dir, sudo: sudo_needed)
      end

      warn "[quarks] Preserved #{preserved.length} modified configuration file(s)" if preserved.any?

      removed
    end

    def ensure_install_root!(install_root)
      return if Dir.exist?(install_root)

      parent = File.dirname(install_root)
      if File.writable?(parent)
        FileUtils.mkdir_p(install_root)
      elsif sudo_path
        install_tool = SystemIntegration.trusted_command("install")
        raise InstallError, "Trusted system install tool is unavailable" unless install_tool
        ok = run_process(sudo_path, install_tool, "-d", "-m", "0755", install_root)
        raise InstallError, "Could not create install root: #{install_root}" unless ok
      else
        raise InstallError, "Install root is not writable and sudo is unavailable: #{install_root}"
      end
    end

    def validate_staging_directory(dest_dir)
      root = File.realpath(dest_dir)
      symlinks = []
      Find.find(dest_dir) do |path|
        next unless File.symlink?(path)
        symlinks << path if path != dest_dir
      end

      return if symlinks.empty?

      symlinks.each do |link|
        target = File.readlink(link)
        raise InstallError, "Invalid symlink target: #{link}" if target.include?("\0")
        raise InstallError, "Absolute symlinks are not allowed in package images: #{link} -> #{target}" if target.start_with?("/")

        resolved = File.expand_path(target, File.dirname(link))
        unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
          raise InstallError, "Symlink escapes staging root: #{link} -> #{target}"
        end
      end
    end

    def perform_install(dest_dir, install_root, sudo: false)
      copy_image_tree(dest_dir, install_root, sudo: sudo)
      @rollback_stack << [:copy, dest_dir, install_root]
    end

    def perform_rollback(install_root, rollback_dir:, backed_up:, sudo: false, error: nil)
      puts "[quarks] Initiating rollback due to: #{error&.message || 'unknown error'}"
      rolled_back = 0
      failed = []

      (@installed_files + backed_up).uniq.sort_by { |path| -path.length }.each do |rel|
        target = File.join(install_root, rel)
        begin
          backup = File.join(rollback_dir, rel)
          if backed_up.include?(rel) && (File.exist?(backup) || File.symlink?(backup))
            remove_path(target, sudo: sudo)
            copy_path(backup, target, sudo: sudo)
          else
            remove_path(target, sudo: sudo)
          end
          rolled_back += 1
        rescue => e
          failed << { path: target, error: e.message }
        end
      end

      prune_empty_dirs(@installed_files, install_root, sudo: sudo)

      puts "[quarks] Rollback complete: #{rolled_back} file(s) removed"
      if failed.any?
        puts "[quarks] Warning: #{failed.length} file(s) could not be removed"
      end
      failed
    end

    def validate_destination_tree!(dest_dir, install_root)
      force = @options[:force] || ENV["QUARKS_FORCE_OVERWRITE"] == "1"
      root = File.expand_path(install_root)
      raise InstallError, "Install root must not be a symlink: #{root}" if File.symlink?(root)

      @installed_files.each do |rel|
        target = File.join(root, rel)
        parent = File.dirname(target)
        until parent == root
          unless Security.path_within?(parent, root, allow_root: false)
            raise InstallError, "Destination path escapes the install root: #{target}"
          end
          raise InstallError, "Destination path traverses a symlink: #{parent}" if File.symlink?(parent)
          parent = File.dirname(parent)
        end

        next unless File.exist?(target) || File.symlink?(target)
        owner = @database.owner_of(rel)
        if owner.nil? && !force
          raise InstallError, "Refusing to overwrite unmanaged path: #{target} (use --force to approve)"
        end

        staged = File.join(dest_dir, rel)
        if File.directory?(target) != File.directory?(staged)
          raise InstallError, "Refusing file/directory type replacement: #{target}"
        end
      end
    end

    def create_rollback_dir
      base = File.join(Quarks::Env.state_root, "var", "tmp", "quarks", "rollback")
      FileUtils.mkdir_p(base, mode: 0o700)
      Dir.mktmpdir("#{@package.name}-", base)
    end

    def backup_existing_paths(paths, install_root, rollback_dir, sudo: false)
      Array(paths).each_with_object([]) do |rel, backed_up|
        source = File.join(install_root, rel)
        next unless File.exist?(source) || File.symlink?(source)

        destination = File.join(rollback_dir, rel)
        FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
        copy_path(source, destination, sudo: sudo)
        backed_up << rel
      end
    end

    def remove_obsolete_upgrade_files(previous, install_root, sudo: false)
      return unless previous

      obsolete = Array(previous[:files]) - @installed_files
      manifest_by_path = Array(previous[:file_manifest]).to_h { |entry| [entry[:path], entry] }
      obsolete.sort_by { |path| -path.length }.each do |rel|
        target = File.join(install_root, rel)
        next unless File.exist?(target) || File.symlink?(target)
        if protected_config_path?(rel) && file_changed?(target, manifest_by_path[rel]) && !@options[:force]
          warn "[quarks] Preserving modified obsolete configuration: #{target}"
          next
        end
        raise InstallError, "Failed to remove obsolete upgrade file: #{target}" unless remove_path(target, sudo: sudo)
      end
      prune_empty_dirs(obsolete, install_root, sudo: sudo)
    end

    def copy_path(source, destination, sudo: false)
      FileUtils.mkdir_p(File.dirname(destination)) unless sudo
      argv = ["/bin/cp", "-a", "--", source, destination]
      ok = sudo ? run_process(sudo_path, *argv) : run_process(*argv)
      raise InstallError, "Failed to copy #{source} to #{destination}" unless ok
      true
    end

    def remove_path(path, sudo: false)
      return true unless File.exist?(path) || File.symlink?(path)

      if sudo
        run_process(sudo_path, "/bin/rm", "-f", "--", path)
      else
        FileUtils.rm_f(path)
      end
      !(File.exist?(path) || File.symlink?(path))
    end

    def cleanup_rollback_dir(path, sudo: false)
      base = File.join(Quarks::Env.state_root, "var", "tmp", "quarks", "rollback")
      return unless path && File.expand_path(path).start_with?(File.expand_path(base) + File::SEPARATOR)

      if sudo
        run_process(sudo_path, "/bin/rm", "-rf", "--", path)
      else
        FileUtils.rm_rf(path)
      end
    end

    def perform_post_install_tasks(dest_dir, install_root, sudo: false)
      @post_install_actions = SystemIntegration.install_handlers(@package, dest_dir, install_root)

      needs_ldconfig = @post_install_actions.any? { |a| a[:type] == :ldconfig }
      if needs_ldconfig
        ok = LdconfigManager.update_ldconfig(
          install_root: install_root,
          dry_run: @options[:pretend],
          elevate: sudo
        )
        raise PostInstallError, "ldconfig update failed" unless ok
      end

      desktop_files = @post_install_actions.select { |a| a[:type] == :desktop_file }
      if desktop_files.any?
        ok = DesktopDatabaseManager.update_desktop_database(
          install_root,
          dry_run: @options[:pretend],
          elevate: sudo
        )
        raise PostInstallError, "desktop database update failed" unless ok
      end

      info_actions = @post_install_actions.select { |a| a[:type] == :info_pages }
      if info_actions.any?
        relative_info_files = info_actions.flat_map { |action| Array(action[:files]) }.uniq
        ok = update_info_database(
          install_root,
          relative_files: relative_info_files,
          dry_run: @options[:pretend],
          elevate: sudo
        )
        raise PostInstallError, "info database update failed" unless ok
      end

      mime_needed = @post_install_actions.any? { |a| a[:type] == :mimedb }
      if mime_needed
        ok = MimedbManager.update_mime_database(install_root, dry_run: @options[:pretend], elevate: sudo)
        raise PostInstallError, "MIME database update failed" unless ok
      end

      gtk_icons = @post_install_actions.any? { |a| a[:type] == :gtk_icon_cache }
      if gtk_icons
        ok = GTKIconCacheManager.update_icon_cache(install_root, dry_run: @options[:pretend], elevate: sudo)
        raise PostInstallError, "GTK icon cache update failed" unless ok
      end
    end

    def perform_pre_uninstall_tasks(pkg_info, install_root, sudo: false)
      alt_name = @package.name.to_s
      if UpdateAlternativesManager.query(alt_name)
        UpdateAlternativesManager.unregister(alt_name, install_root, dry_run: @options[:pretend])
      end
    end

    def perform_post_uninstall_tasks(install_root, sudo: false)
      ldconfig_ok = LdconfigManager.update_ldconfig(
        install_root: install_root,
        dry_run: @options[:pretend],
        elevate: sudo
      )
      desktop_ok = DesktopDatabaseManager.update_desktop_database(
        install_root,
        dry_run: @options[:pretend],
        elevate: sudo
      )
      raise PostInstallError, "post-uninstall cache update failed" unless ldconfig_ok && desktop_ok
      true
    end

    def collect_image_files(dest_dir)
      collect_image_manifest(dest_dir).map { |entry| entry[:path] }
    end

    def collect_image_manifest(dest_dir)
      files = []
      Find.find(dest_dir) do |path|
        next if path == dest_dir
        stat = File.lstat(path)
        if (stat.mode & 0o6000).positive?
          raise InstallError, "Set-ID files/directories require an explicit privileged-file policy: #{path}"
        end
        next if stat.directory?
        unless stat.file? || stat.symlink?
          raise InstallError, "Package image contains an unsupported special file: #{path}"
        end

        rel = path.sub(dest_dir, "").sub(%r{^/+}, "")
        next if rel.empty?
        kind = stat.symlink? ? "symlink" : "file"
        digest_input = stat.symlink? ? "symlink\0#{File.readlink(path)}" : nil
        sha256 = digest_input ? Digest::SHA256.hexdigest(digest_input) : Digest::SHA256.file(path).hexdigest
        files << { path: rel, sha256: sha256, size: stat.size, mode: stat.mode & 0o7777, kind: kind }
      end
      files.sort_by { |entry| entry[:path] }.uniq { |entry| entry[:path] }
    end

    def protected_config_path?(relative_path)
      clean = relative_path.to_s.sub(%r{\A/+}, "")
      clean.start_with?("etc/", "usr/local/etc/")
    end

    def file_changed?(path, manifest_entry)
      expected = manifest_entry && manifest_entry[:sha256]
      return true unless expected

      actual = if File.symlink?(path)
                 Digest::SHA256.hexdigest("symlink\0#{File.readlink(path)}")
               elsif File.file?(path)
                 Digest::SHA256.file(path).hexdigest
               end
      actual != expected
    rescue
      true
    end

    def verify_installed_manifest!(install_root)
      @file_manifest.each do |entry|
        target = File.join(install_root, entry[:path])
        unless installed_entry_matches?(target, entry)
          raise InstallError, "Installed file does not match staged content: #{entry[:path]}"
        end
      end
      true
    end

    def copy_image_tree(src_dir, install_root, sudo: false)
      cmd = ["/bin/cp", "-a", "--no-preserve=ownership", "--", "#{src_dir}/.", install_root]
      ok = sudo ? run_process(sudo_path, *cmd) : run_process(*cmd)
      return if ok

      raise InstallError, <<~MSG.strip
        Failed to copy staged files into install root:

          #{install_root}

        Fix permissions or use a writable QUARKS_ROOT.
      MSG
    end

    def installed_entry_matches?(path, entry)
      return false unless File.exist?(path) || File.symlink?(path)

      stat = File.lstat(path)
      actual_kind = stat.symlink? ? "symlink" : (stat.file? ? "file" : "special")
      return false unless actual_kind == entry[:kind]
      return false unless (stat.mode & 0o7777) == entry[:mode]
      return false unless stat.size == entry[:size]

      actual_hash = if stat.symlink?
                      Digest::SHA256.hexdigest("symlink\0#{File.readlink(path)}")
                    else
                      Digest::SHA256.file(path).hexdigest
                    end
      actual_hash == entry[:sha256]
    rescue SystemCallError
      false
    end

    def rollback_files(files, install_root, sudo: false)
      files.sort_by { |path| -path.length }.each do |rel|
        target = File.join(install_root, rel)
        begin
          if sudo
            run_process(sudo_path, "/bin/rm", "-f", "--", target)
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
            run_process(sudo_path, "/bin/rmdir", "--", abs)
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
      test = File.join(path, ".quarks_write_test_#{Process.pid}")
      File.write(test, "ok")
      File.delete(test)
      true
    rescue
      false
    end

    def update_info_database(install_root, relative_files: nil, dry_run: false, elevate: false)
      return true unless SystemIntegration.command_available?("install-info")

      info_files = if relative_files
                     Array(relative_files).map { |path| File.join(install_root, path.to_s.sub(%r{\A/+}, "")) }
                                          .select { |path| File.file?(path) }
                   else
                     find_info_files(install_root)
                   end
      info_files.each do |file|
        next if File.basename(file) == "dir"

        directory_file = File.join(File.dirname(file), "dir")
        if dry_run
          puts "[quarks] Would run: install-info #{file} #{directory_file}"
        else
          ok = SystemIntegration.run_quiet(
            "install-info", file, directory_file,
            elevate: elevate
          )
          return false unless ok
        end
      end

      true
    rescue => e
      warn "[quarks] Warning: info database update failed: #{e.message}"
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
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        File.executable?(File.join(directory, name.to_s))
      end
    end

    def sudo_path
      SystemIntegration.trusted_command("sudo")
    end

    def run_process(*argv)
      system(PROCESS_ENV, *argv, unsetenv_others: true)
    end
  end
end
