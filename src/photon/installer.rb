# frozen_string_literal: true

require "fileutils"
require "find"

module Photon
  class Installer
    def initialize(package, database, options: {})
      @package = package
      @database = database
      @options = options || {}
    end

    def install(dest_dir)
      raise "Staging directory does not exist: #{dest_dir}" unless Dir.exist?(dest_dir)

      install_root = Database::PHOTON_ROOT
      FileUtils.mkdir_p(install_root) unless Dir.exist?(install_root)

      installed_files = collect_image_files(dest_dir)
      collisions = @database.find_collisions(installed_files, exclude_package: @package.name)
      if collisions.any?
        preview = collisions.first(12).map { |c| "  #{c[:path]} (owned by #{c[:owner]})" }.join("\n")
        raise <<~MSG.strip
          Cannot install #{@package.atom}: file ownership collision detected.

          #{preview}

          Resolve the conflicting package(s) first.
        MSG
      end

      sudo_needed = !writable_dir?(install_root)
      start_time = Time.now

      copy_image_tree(dest_dir, install_root, sudo: sudo_needed)
      install_time = Time.now - start_time

      begin
        ok = @database.add_package(@package, files: installed_files, install_time: install_time)
        raise "Failed to register package in database" unless ok
      rescue => e
        rollback_files(installed_files, install_root, sudo: sudo_needed)
        raise e
      end

      installed_files
    end

    def uninstall
      pkg_info = @database.get_package(@package.name)
      raise "Package not in database: #{@package.name}" unless pkg_info

      install_root = Database::PHOTON_ROOT
      sudo_needed = !writable_dir?(install_root)
      files = Array(pkg_info[:files])
      removed = 0

      files.sort_by { |path| -path.length }.each do |rel|
        target = File.join(install_root, rel.sub(%r{^/+}, ""))
        next unless File.exist?(target) || File.symlink?(target)

        if sudo_needed
          removed += 1 if system("sudo", "rm", "-f", target)
        else
          begin
            FileUtils.rm_f(target)
            removed += 1
          rescue
            nil
          end
        end
      end

      prune_empty_dirs(files, install_root, sudo: sudo_needed)
      @database.remove_package(@package.name)
      removed
    end

    private

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

      raise <<~MSG.strip
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
  end
end
