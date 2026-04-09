# frozen_string_literal: true

require "fileutils"
require "find"

module Quarks
  class SystemIntegration
    LIBRARY_PATTERNS = [
      /\blib.*\.so(\.\d+)*$/,
      /\blib.*\.a$/,
      /\blib.*\.la$/,
      /\/lib[^\/]*$/,
      /\/lib64[^\/]*$/
    ].freeze

    DESKTOP_FILE_PATTERNS = [
      /\.desktop$/,
      /\.desktop\.in$/
    ].freeze

    MAN_PAGE_PATTERNS = [
      /\.man$/,
      /\.man\.\d$/,
      /\.man\.n$/,
      /\.1$/, /\.2$/, /\.3$/, /\.4$/, /\.5$/,
      /\.6$/, /\.7$/, /\.8$/,
      /\/man\//,
      /\/help\//
    ].freeze

    attr_accessor :actions

    def initialize(package, install_root)
      @package = package
      @install_root = install_root
      @actions = []
    end

    def self.install_handlers(package, dest_dir, install_root)
      integrator = new(package, install_root)
      integrator.install_handlers_impl(dest_dir)
      integrator.actions
    end

    def install_handlers_impl(dest_dir)
      files = collect_installed_files(dest_dir)
      return if files.empty?

      process_libraries(files)
      process_desktop_files(files)
      process_man_pages(files)
      process_alternatives(files)
      process_info_pages(files)
      register_shared_libraries(files)
    end

    private

    def collect_installed_files(dest_dir)
      files = []
      Find.find(dest_dir) do |path|
        next unless File.file?(path) || File.symlink?(path)
        rel = path.sub(dest_dir, "").sub(%r{^/+}, "")
        files << { abs: path, rel: rel }
      end
      files
    end

    def process_libraries(files)
      lib_files = files.select { |f| library_file?(f[:rel]) }
      return if lib_files.empty?

      @actions << {
        type: :libraries,
        files: lib_files.map { |f| f[:rel] },
        message: "Detected #{lib_files.length} library file(s)"
      }
    end

    def process_desktop_files(files)
      desktop_files = files.select { |f| desktop_file?(f[:rel]) }
      return if desktop_files.empty?

      desktop_files.each do |f|
        @actions << {
          type: :desktop_file,
          file: f[:rel],
          abs_path: f[:abs]
        }
      end
    end

    def process_man_pages(files)
      man_files = files.select { |f| man_page?(f[:rel]) }
      return if man_files.empty?

      categorized = categorize_man_pages(man_files)
      categorized.each do |section, pages|
        @actions << {
          type: :man_pages,
          section: section,
          files: pages.map { |f| f[:rel] }
        }
      end
    end

    def process_alternatives(files)
      bin_files = files.select { |f| executable_in_bin?(f[:rel]) }
      return if bin_files.empty?

      bin_files.each do |f|
        name = File.basename(f[:rel])
        @actions << {
          type: :alternatives_register,
          name: name,
          path: f[:rel]
        }
      end
    end

    def process_info_pages(files)
      info_files = files.select { |f| info_page?(f[:rel]) }
      return if info_files.empty?

      @actions << {
        type: :info_pages,
        files: info_files.map { |f| f[:rel] }
      }
    end

    def register_shared_libraries(files)
      lib_files = files.select { |f| library_file?(f[:rel]) }
      return if lib_files.empty?

      @actions << {
        type: :ldconfig,
        trigger: true,
        message: "Library installation detected, ldconfig will be updated"
      }
    end

    def library_file?(path)
      return false if path.nil? || path.empty?

      ext = File.extname(path)
      return true if [".so", ".a", ".la"].any? { |e| path.end_with?(e) }

      if path.include?("/lib") || path.include?("/lib64")
        return true if path =~ /\.so(\.\d+)*$/
        return true if path =~ /\.a$/
      end

      false
    end

    def desktop_file?(path)
      return false if path.nil? || path.empty?
      path.end_with?(".desktop") || path.end_with?(".desktop.in")
    end

    def man_page?(path)
      return false if path.nil? || path.empty?

      return true if path.start_with?("usr/share/man/")
      return true if path.start_with?("usr/libdata/lintian/")
      return true if path =~ /\/man\//
      return true if path =~ /\.(1|2|3|4|5|6|7|8|9)$/
      return true if path =~ /\.(1|2|3|4|5|6|7|8|9)stanza$/

      false
    end

    def executable_in_bin?(path)
      return false if path.nil? || path.empty?

      bin_dirs = ["bin/", "sbin/", "usr/bin/", "usr/sbin/", "usr/local/bin/", "usr/local/sbin/"]
      return false unless bin_dirs.any? { |d| path.start_with?(d) }

      abs_path = File.join(@install_root, path)
      File.executable?(abs_path) rescue false
    end

    def info_page?(path)
      return false if path.nil? || path.empty?
      path.end_with?(".info") || path.include?("/info/")
    end

    def categorize_man_pages(files)
      sections = {}
      files.each do |f|
        section = infer_man_section(f[:rel])
        sections[section] ||= []
        sections[section] << f
      end
      sections
    end

    def infer_man_section(path)
      basename = File.basename(path)

      section_match = basename.match(/(\d+)(stanza)?$/)
      return "man#{section_match[1]}" if section_match

      case path
      when /\/man1\// then "man1"
      when /\/man2\// then "man2"
      when /\/man3\// then "man3"
      when /\/man4\// then "man4"
      when /\/man5\// then "man5"
      when /\/man6\// then "man6"
      when /\/man7\// then "man7"
      when /\/man8\// then "man8"
      when /\/man9\// then "man9"
      else "man1"
      end
    end
  end

  class LdconfigManager
    def self.update_ldconfig(dry_run: false)
      if dry_run
        puts "[quarks] Would run: ldconfig"
        return true
      end

      system("ldconfig 2>/dev/null")
      $?.success?
    rescue => e
      warn "[quarks] ldconfig update failed: #{e.message}"
      false
    end

    def self.cache_libraries(install_root)
      lib_dirs = find_library_directories(install_root)
      return if lib_dirs.empty?

      lib_dirs.each do |dir|
        ensure_library_symlinks(dir)
      end
    end

    def self.find_library_directories(root)
      lib_dirs = []
      search_paths = [
        File.join(root, "lib"),
        File.join(root, "lib64"),
        File.join(root, "usr", "lib"),
        File.join(root, "usr", "lib64"),
        File.join(root, "usr", "local", "lib"),
        File.join(root, "usr", "local", "lib64")
      ]

      search_paths.each do |path|
        if Dir.exist?(path) && !Dir.empty?(path)
          lib_dirs << path
        end
      end

      lib_dirs
    end

    def self.ensure_library_symlinks(dir)
      return unless Dir.exist?(dir)

      Dir.glob(File.join(dir, "*.so*")).each do |lib|
        next unless File.symlink?(lib)

        target = File.readlink(lib)
        next if target.start_with?("/")

        libname = File.basename(lib)
        parts = libname.split(".so")

        next unless parts.length >= 2

        base_name = parts[0] + ".so"
        base_path = File.join(dir, base_name)

        unless File.exist?(base_path)
          File.symlink(target, base_path)
        end
      end
    end
  end

  class DesktopDatabaseManager
    def self.update_desktop_database(install_root, dry_run: false)
      desktop_files = find_desktop_files(install_root)
      return if desktop_files.empty?

      if dry_run
        puts "[quarks] Would update desktop database with #{desktop_files.length} file(s)"
        return true
      end

      desktop_files.each do |file|
        validate_desktop_file(file)
      end

      true
    rescue => e
      warn "[quarks] Desktop database update failed: #{e.message}"
      false
    end

    def self.find_desktop_files(root)
      files = []
      patterns = [
        File.join(root, "usr", "share", "applications", "*.desktop"),
        File.join(root, "usr", "local", "share", "applications", "*.desktop")
      ]

      patterns.each do |pattern|
        Dir.glob(pattern).each do |file|
          files << file if File.file?(file)
        end
      end

      files
    end

    def self.validate_desktop_file(file)
      return true unless command_exists?("desktop-file-validate")

      system("desktop-file-validate #{Shellwords.escape(file)} 2>/dev/null")
      $?.success?
    rescue
      false
    end

    def self.command_exists?(name)
      system("command -v #{Shellwords.escape(name)} >/dev/null 2>&1")
    end
  end

  class GIODesktopManager
    def self.register_desktop_file(file, dry_run: false)
      return false unless command_exists?("gio")

      if dry_run
        puts "[quarks] Would register desktop file: #{file}"
        return true
      end

      system("gio set #{Shellwords.escape(file)} metadata::trusted true 2>/dev/null")
      $?.success?
    rescue => e
      warn "[quarks] GIO desktop registration failed: #{e.message}"
      false
    end

    def self.command_exists?(name)
      system("command -v #{Shellwords.escape(name)} >/dev/null 2>&1")
    end
  end

  class UpdateAlternativesManager
    ALT_DB_PATH = File.join(Quarks::Env.state_root, "var", "lib", "quarks", "alternatives.json")

    def self.initialize!
      FileUtils.mkdir_p(File.dirname(ALT_DB_PATH))
      unless File.exist?(ALT_DB_PATH)
        File.write(ALT_DB_PATH, JSON.generate({}))
      end
    end

    def self.register(name, path, priority: 50, dry_run: false)
      initialize!

      db = load_db
      db[name] ||= { priority: priority, links: {} }
      db[name][:links][path] = { priority: priority }

      if dry_run
        puts "[quarks] Would register alternative: #{name} -> #{path} (priority: #{priority})"
        return true
      end

      save_db(db)
      create_symlink(name, path)
    end

    def self.unregister(name, path, dry_run: false)
      db = load_db
      return false unless db[name]

      db[name][:links].delete(path)

      if db[name][:links].empty?
        db.delete(name)
      end

      if dry_run
        puts "[quarks] Would unregister alternative: #{name} -> #{path}"
      end

      save_db(db)
    end

    def self.query(name)
      db = load_db
      db[name]
    end

    def self.list
      load_db
    end

    def self.set_active(name, path, dry_run: false)
      db = load_db
      return false unless db[name] && db[name][:links][path]

      db[name][:active] = path

      if dry_run
        puts "[quarks] Would set active alternative: #{name} -> #{path}"
        return true
      end

      save_db(db)
      create_symlink(name, path)
    end

    private

    def self.load_db
      return {} unless File.exist?(ALT_DB_PATH)

      JSON.parse(File.read(ALT_DB_PATH))
    rescue JSON::ParserError
      {}
    end

    def self.save_db(db)
      File.write(ALT_DB_PATH, JSON.pretty_generate(db))
    end

    def self.create_symlink(name, target_path)
      link_path = File.join("/usr/bin", name)
      return false unless target_path.start_with?("/")

      begin
        if File.exist?(link_path) || File.symlink?(link_path)
          FileUtils.rm_f(link_path)
        end
        FileUtils.ln_s(target_path, link_path)
        true
      rescue => e
        warn "[quarks] Failed to create alternative symlink: #{e.message}"
        false
      end
    end
  end

  class MimedbManager
    def self.update_mime_database(install_root, dry_run: false)
      return true unless command_exists?("update-mime-database")

      mime_dirs = [
        File.join(install_root, "usr", "share", "mime"),
        File.join(install_root, "usr", "local", "share", "mime")
      ]

      updated = false
      mime_dirs.each do |dir|
        next unless Dir.exist?(dir)

        if dry_run
          puts "[quarks] Would update MIME database in: #{dir}"
        else
          system("update-mime-database #{Shellwords.escape(dir)} 2>/dev/null")
          updated ||= $?.success?
        end
      end

      updated
    end

    def self.command_exists?(name)
      system("command -v #{Shellwords.escape(name)} >/dev/null 2>&1")
    end
  end

  class GTKIconCacheManager
    def self.update_icon_cache(install_root, dry_run: false)
      return true unless command_exists?("gtk-update-icon-cache")

      icon_dirs = find_icon_directories(install_root)
      updated = false

      icon_dirs.each do |dir|
        if dry_run
          puts "[quarks] Would update icon cache in: #{dir}"
        else
          system("gtk-update-icon-cache -f -t #{Shellwords.escape(dir)} 2>/dev/null")
          updated ||= $?.success?
        end
      end

      updated
    end

    def self.find_icon_directories(root)
      dirs = []
      patterns = [
        File.join(root, "usr", "share", "icons", "*"),
        File.join(root, "usr", "local", "share", "icons", "*")
      ]

      patterns.each do |pattern|
        Dir.glob(pattern).each do |dir|
          next unless Dir.exist?(dir)
          next unless File.exist?(File.join(dir, "index.theme"))

          dirs << dir
        end
      end

      dirs
    end

    def self.command_exists?(name)
      system("command -v #{Shellwords.escape(name)} >/dev/null 2>&1")
    end
  end
end
