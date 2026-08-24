# frozen_string_literal: true

require "fileutils"
require "find"
require "shellwords"
require "tmpdir"
require "digest"
require "open3"
require "securerandom"

require "quarks/generated_paths"
require "quarks/operation_lock"
require "quarks/system_integration"

module Quarks
  class Installer
    class InstallError < StandardError; end
    class RollbackError < StandardError; end
    class PostInstallError < StandardError; end
    PROCESS_ENV = { "PATH" => "/usr/bin:/usr/sbin:/bin:/sbin", "LANG" => "C", "LC_ALL" => "C" }.freeze
    PRIVILEGED_ROLLBACK_BASE = "/var/tmp".freeze
    PRIVILEGED_ROLLBACK_PREFIX = "quarks-rollback-".freeze

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
      rollback_dir = create_rollback_dir(sudo: sudo_needed)
      backed_up = []

      begin
        backed_up = backup_existing_paths(backup_paths, install_root, rollback_dir, sudo: sudo_needed)
        perform_install(dest_dir, install_root, sudo: sudo_needed)
        verify_installed_manifest!(install_root)
        remove_obsolete_upgrade_files(previous, install_root, sudo: sudo_needed)
        install_time = Time.now - start_time
        ok = @database.add_package(
          @package,
          files: @file_manifest,
          install_time: install_time,
          world: @options[:world] && !@options[:oneshot]
        )
        raise InstallError, "Failed to register package in database" unless ok

        perform_post_install_tasks(dest_dir, install_root, previous: previous, sudo: sudo_needed)

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
        cache_files = (@installed_files + Array(previous&.dig(:files))).uniq
        unless refresh_system_caches(cache_files, install_root, sudo: sudo_needed, dry_run: false)
          rollback_failures << { path: install_root, error: "system caches could not be restored" }
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
      rollback_dir = create_rollback_dir(sudo: sudo_needed)
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

        perform_post_uninstall_tasks(pkg_info, install_root, sudo: sudo_needed)
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
        unless refresh_system_caches(Array(pkg_info[:files]), install_root, sudo: sudo_needed, dry_run: false)
          rollback_failures << { path: install_root, error: "system caches could not be restored" }
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
        validate_target_parent!(target, root)
        next unless File.exist?(target) || File.symlink?(target)

        stat = File.lstat(target)
        raise InstallError, "Refusing to replace a destination directory: #{target}" if stat.directory?
        unless stat.file? || stat.symlink?
          raise InstallError, "Refusing to replace a special destination object: #{target}"
        end

        owner = @database.owner_of(rel)
        if owner.nil? && !force
          raise InstallError, "Refusing to overwrite unmanaged path: #{target} (use --force to approve)"
        end

        staged = File.join(dest_dir, rel)
        staged_stat = File.lstat(staged)
        unless staged_stat.file? || staged_stat.symlink?
          raise InstallError, "Unsupported staged object: #{staged}"
        end
      end
    end

    def validate_target_parent!(target, root)
      parent = File.dirname(target)
      until parent == root
        unless Security.path_within?(parent, root, allow_root: false)
          raise InstallError, "Destination path escapes the install root: #{target}"
        end
        raise InstallError, "Destination path traverses a symlink: #{parent}" if File.symlink?(parent)
        if File.exist?(parent) && !File.directory?(parent)
          raise InstallError, "Destination parent is not a directory: #{parent}"
        end
        parent = File.dirname(parent)
      end
    end

    def create_rollback_dir(sudo: false)
      unless sudo
        base = File.join(Quarks::Env.state_root, "var", "tmp", "quarks", "rollback")
        Security.secure_directory(base)
        return Dir.mktmpdir("#{@package.name}-", base)
      end

      mktemp_tool = SystemIntegration.trusted_command("mktemp")
      raise InstallError, "Trusted system temporary-directory tools are unavailable" unless mktemp_tool && sudo_path

      template = "#{PRIVILEGED_ROLLBACK_PREFIX}#{@package.name.to_s.gsub(/[^A-Za-z0-9._-]/, "_")}-XXXXXXXX"
      output, status = Open3.capture2e(PROCESS_ENV, sudo_path, mktemp_tool, "-d", "-p", PRIVILEGED_ROLLBACK_BASE, template, unsetenv_others: true)
      path = output.to_s.strip
      unless status.success? && Security.path_within?(path, PRIVILEGED_ROLLBACK_BASE, allow_root: false)
        raise InstallError, "Could not create privileged rollback directory"
      end
      path
    end

    def backup_existing_paths(paths, install_root, rollback_dir, sudo: false)
      Array(paths).each_with_object([]) do |rel, backed_up|
        source = File.join(install_root, rel)
        next unless File.exist?(source) || File.symlink?(source)

        destination = File.join(rollback_dir, rel)
        ensure_parent_directory(destination, sudo: sudo, mode: 0o700)
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
      ensure_parent_directory(destination, sudo: sudo)
      argv = ["/bin/cp", "-a", "--", source, destination]
      ok = sudo ? run_process(sudo_path, *argv) : run_process(*argv)
      raise InstallError, "Failed to copy #{source} to #{destination}" unless ok
      true
    end

    def ensure_parent_directory(path, sudo: false, mode: 0o755)
      parent = File.dirname(path)
      if File.exist?(parent) || File.symlink?(parent)
        raise InstallError, "Parent directory is a symlink: #{parent}" if File.symlink?(parent)
        raise InstallError, "Parent path is not a directory: #{parent}" unless File.directory?(parent)
        return true
      end

      if sudo
        install_tool = SystemIntegration.trusted_command("install")
        raise InstallError, "Trusted system install tool is unavailable" unless install_tool
        ok = run_process(sudo_path, install_tool, "-d", "-m", format("%04o", mode), parent)
        raise InstallError, "Could not create directory: #{parent}" unless ok
      else
        FileUtils.mkdir_p(parent, mode: mode)
      end
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
      base = sudo ? PRIVILEGED_ROLLBACK_BASE : File.join(Quarks::Env.state_root, "var", "tmp", "quarks", "rollback")
      return unless path && Security.path_within?(path, base, allow_root: false)
      return if sudo && !File.basename(path).start_with?(PRIVILEGED_ROLLBACK_PREFIX)

      if sudo
        run_process(sudo_path, "/bin/rm", "-rf", "--", path)
      else
        FileUtils.rm_rf(path)
      end
    end

    def perform_post_install_tasks(_dest_dir, install_root, previous: nil, sudo: false)
      @post_install_actions = []
      files = (@installed_files + Array(previous&.dig(:files))).uniq
      unless refresh_system_caches(files, install_root, sudo: sudo, dry_run: @options[:pretend])
        raise PostInstallError, "post-install cache update failed"
      end
      true
    end

    def perform_pre_uninstall_tasks(pkg_info, install_root, sudo: false)
      Array(pkg_info[:files]).each do |rel|
        next unless rel.match?(%r{\A(?:usr/)?(?:local/)?(?:s?bin)/[^/]+\z})
        name = File.basename(rel)
        target = File.join(install_root, rel)
        entry = UpdateAlternativesManager.query(name)
        next unless entry.is_a?(Hash) && entry.fetch("links", {}).key?(target)
        UpdateAlternativesManager.unregister(name, target, dry_run: @options[:pretend])
      rescue ArgumentError
        next
      end
    end

    def perform_post_uninstall_tasks(pkg_info, install_root, sudo: false)
      unless refresh_system_caches(Array(pkg_info[:files]), install_root, sudo: sudo, dry_run: @options[:pretend])
        raise PostInstallError, "post-uninstall cache update failed"
      end
      true
    end

    def refresh_system_caches(files, install_root, sudo:, dry_run:)
      paths = Array(files)
      results = []
      if paths.any? { |path| path.match?(%r{(?:\A|/)lib(?:64)?/.*\.so(?:\.\d+)*\z}) }
        results << LdconfigManager.update_ldconfig(install_root: install_root, dry_run: dry_run, elevate: sudo)
      end
      if paths.any? { |path| path.start_with?("usr/share/applications/", "usr/local/share/applications/") && path.end_with?(".desktop") }
        results << DesktopDatabaseManager.update_desktop_database(install_root, dry_run: dry_run, elevate: sudo)
      end
      if paths.any? { |path| File.basename(path).match?(/\.info(?:\.(?:gz|bz2|xz|zst))?\z/) }
        results << rebuild_info_database(install_root, dry_run: dry_run, elevate: sudo)
      end
      if paths.any? { |path| path.start_with?("usr/share/mime/", "usr/local/share/mime/") }
        results << MimedbManager.update_mime_database(install_root, dry_run: dry_run, elevate: sudo)
      end
      if paths.any? { |path| path.start_with?("usr/share/icons/", "usr/local/share/icons/") }
        results << GTKIconCacheManager.update_icon_cache(install_root, dry_run: dry_run, elevate: sudo)
      end
      if paths.any? { |path| path.start_with?("usr/share/glib-2.0/schemas/", "usr/local/share/glib-2.0/schemas/") }
        results << GSettingsSchemaManager.compile(install_root, dry_run: dry_run, elevate: sudo)
      end
      results.none?(false)
    rescue
      false
    end

    def collect_image_files(dest_dir)
      collect_image_manifest(dest_dir).map { |entry| entry[:path] }
    end

    def collect_image_manifest(dest_dir)
      root = File.realpath(dest_dir)
      files = []
      directories = []
      Find.find(dest_dir) do |path|
        next if path == dest_dir
        stat = File.lstat(path)
        if (stat.mode & 0o6000).positive?
          raise InstallError, "Set-ID files/directories require an explicit privileged-file policy: #{path}"
        end

        rel = path.delete_prefix(dest_dir).sub(%r{\A/+}, "")
        next if rel.empty?
        if stat.directory?
          directories << { path: rel, mode: stat.mode & 0o777 }
          next
        end
        unless stat.file? || stat.symlink?
          raise InstallError, "Package image contains an unsupported special file: #{path}"
        end
        if stat.symlink?
          target = File.readlink(path)
          raise InstallError, "Invalid symlink target: #{path}" if target.include?("\0")
          raise InstallError, "Absolute symlinks are not allowed in package images: #{path} -> #{target}" if target.start_with?("/")
          resolved = File.expand_path(target, File.dirname(path))
          unless resolved == root || resolved.start_with?(root + File::SEPARATOR)
            raise InstallError, "Symlink escapes staging root: #{path} -> #{target}"
          end
        end
        if GeneratedPaths.generated?(rel)
          FileUtils.rm_f(path)
          next
        end

        kind = stat.symlink? ? "symlink" : "file"
        digest_input = stat.symlink? ? "symlink\0#{File.readlink(path)}" : nil
        sha256 = digest_input ? Digest::SHA256.hexdigest(digest_input) : Digest::SHA256.file(path).hexdigest
        files << { path: rel, sha256: sha256, size: stat.size, mode: stat.mode & 0o7777, kind: kind }
      end
      @directory_manifest = directories.sort_by { |entry| entry[:path].count(File::SEPARATOR) }
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
      directories = @directory_manifest
      unless directories
        directories = []
        Find.find(src_dir) do |path|
          next if path == src_dir
          stat = File.lstat(path)
          rel = path.delete_prefix(src_dir).sub(%r{\A/+}, "")
          directories << { path: rel, mode: stat.mode & 0o777 } if stat.directory?
        end
        directories.sort_by! { |entry| entry[:path].count(File::SEPARATOR) }
      end
      directories.each do |directory|
        target = File.join(install_root, directory[:path])
        if File.exist?(target) || File.symlink?(target)
          stat = File.lstat(target)
          raise InstallError, "Destination directory is a symlink: #{target}" if stat.symlink?
          raise InstallError, "Destination directory path is not a directory: #{target}" unless stat.directory?
          next
        end
        if sudo
          install_tool = SystemIntegration.trusted_command("install")
          raise InstallError, "Trusted system install tool is unavailable" unless install_tool
          raise InstallError, "Failed to create destination directory: #{target}" unless run_process(sudo_path, install_tool, "-d", "-m", format("%04o", directory[:mode]), target)
        else
          Dir.mkdir(target, directory[:mode])
        end
      end

      hardlinks = {}
      @file_manifest.each do |entry|
        rel = entry[:path]
        source = File.join(src_dir, rel)
        target = File.join(install_root, rel)
        validate_target_parent!(target, File.expand_path(install_root))
        raise InstallError, "Failed to replace destination object: #{target}" unless remove_path(target, sudo: sudo)
        ensure_parent_directory(target, sudo: sudo)

        stat = File.lstat(source)
        inode_key = stat.file? && stat.nlink > 1 ? [stat.dev, stat.ino] : nil
        previous_target = inode_key && hardlinks[inode_key]
        if previous_target
          argv = ["/bin/ln", "--", previous_target, target]
          ok = sudo ? run_process(sudo_path, *argv) : run_process(*argv)
        else
          argv = ["/bin/cp", "-a", "--no-preserve=ownership", "--", source, target]
          ok = sudo ? run_process(sudo_path, *argv) : run_process(*argv)
          hardlinks[inode_key] = target if ok && inode_key
        end
        raise InstallError, "Failed to install staged object: #{rel}" unless ok
      end
      true
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
      test = File.join(path, ".quarks-write-#{Process.pid}-#{SecureRandom.hex(8)}")
      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(test, flags, 0o600) { |file| file.write("ok") }
      File.delete(test)
      true
    rescue
      false
    ensure
      FileUtils.rm_f(test) if defined?(test) && test && File.exist?(test)
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

    def rebuild_info_database(install_root, dry_run: false, elevate: false)
      return true unless SystemIntegration.command_available?("install-info")
      [
        File.join(install_root, "usr", "share", "info"),
        File.join(install_root, "usr", "local", "share", "info")
      ].each do |directory|
        next unless Dir.exist?(directory)
        dir_file = File.join(directory, "dir")
        if dry_run
          puts "[quarks] Would rebuild info index in #{directory}"
        else
          remove_path(dir_file, sudo: elevate) if File.exist?(dir_file) || File.symlink?(dir_file)
        end
      end
      update_info_database(install_root, relative_files: nil, dry_run: dry_run, elevate: elevate)
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
