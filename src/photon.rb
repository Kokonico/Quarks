#!/usr/bin/env ruby
# frozen_string_literal: true

require "find"
require "fileutils"

if ENV["PHOTON_TRACE_SYSTEM"] == "1"
  module Kernel
    alias __photon_system system

    def system(*args)
      warn "PHOTON_TRACE system(#{args.map(&:inspect).join(', ')})\n  from: #{caller(1, 5).join("\n        ")}"
      __photon_system(*args)
    end
  end
end

PHOTON_LIB_DIR = File.expand_path("../src", __dir__)
$LOAD_PATH.unshift(PHOTON_LIB_DIR) unless $LOAD_PATH.include?(PHOTON_LIB_DIR)

require "photon/ui"
require "photon/config"
require "photon/env"
Photon::Env.bootstrap!
require "photon/package"
require "photon/database"
require "photon/repository"
require "photon/resolver"
require "photon/builder"
require "photon/installer"
require "photon/path_integration"

module Photon
  VERSION = "1.4.0"
  AUTHOR  = "Photon Developers"

  class CLI
    ROOT_COMMANDS = %w[
      install i emerge
      remove uninstall r rm unmerge
      clean eclean
      compact-db
      setup-path
    ].freeze

    def initialize
      ensure_admin_paths!

      @database = Database.new
      @repository = Repository.new
      @options = {
        verbose: true,
        quiet: false,
        pretend: false,
        ask: true,
        oneshot: false,
        nodeps: false,
        fetchonly: false,
        resume: false,
        keep_going: false,
        jobs: Photon::Env.jobs,
        force: false,
        debug: false,
        warnings: false
      }
    end

    def run(args)
      parse_global_flags!(args)

      if args.empty?
        show_help
        return
      end

      maybe_reexec_with_sudo!(args.first.to_s)
      command = args.shift.to_s

      case command
      when "install", "i", "emerge" then install_packages(args)
      when "remove", "uninstall", "r", "rm", "unmerge" then remove_packages(args)
      when "search", "s", "find" then search_packages(args)
      when "list", "l", "ls", "qlist" then list_installed
      when "info", "show", "metadata" then show_package_info(args.first)
      when "files" then show_package_files(args.first)
      when "which" then which_command(args.first)
      when "owner" then owner_of_path(args.first)
      when "update", "sync" then update_repository
      when "upgrade", "up", "world" then upgrade_packages
      when "clean", "eclean" then clean_cache
      when "doctor", "check" then run_doctor
      when "debug" then debug_info
      when "version", "--version" then show_version
      when "help", "-h", "--help" then show_help
      when "paths" then show_paths
      when "env" then print_env
      when "setup-path" then setup_path
      when "compact-db" then compact_db
      else
        UI.error "Unknown command: #{command}"
        puts "Run #{UI::COLORS[:cyan]}photon help#{UI::COLORS[:reset]} for usage information."
        exit 1
      end
    rescue Interrupt
      puts
      portage_msg("Interrupted by user", :warn)
      exit 130
    rescue => e
      portage_msg(e.message, :error)

      if @options[:debug] || Photon::Env.debug?
        puts
        puts "#{UI::COLORS[:red]}Stack trace:#{UI::COLORS[:reset]}"
        puts Array(e.backtrace).map { |line| "  #{line}" }.join("\n")
      else
        puts "#{UI::COLORS[:dim]}Run with #{UI::COLORS[:cyan]}--debug#{UI::COLORS[:reset]}#{UI::COLORS[:dim]} for full stack trace#{UI::COLORS[:reset]}"
      end

      exit 1
    end

    private

    def maybe_reexec_with_sudo!(command)
      return if command.empty?
      return unless ROOT_COMMANDS.include?(command)
      return if Process.uid.zero?
      return if ENV["PHOTON_SUDO_REEXEC"] == "1"
      return if ENV["PHOTON_NO_SUDO"] == "1"

      install_root = Database::PHOTON_ROOT
      writable = File.writable?(install_root) || (!File.exist?(install_root) && File.writable?(File.dirname(install_root)))
      return if writable

      unless command_exists?("sudo")
        raise <<~MSG.strip
          Insufficient permissions!

          This command needs root access because your install root is:

            #{install_root}

          Fix options:
            1) Run with sudo:
                 sudo photon #{ARGV.join(' ')}

            2) Or switch to a user install root with PHOTON_ROOT.
        MSG
      end

      puts "#{UI::COLORS[:yellow]}>>>#{UI::COLORS[:reset]} Elevated permissions required for '#{command}'. Re-running with sudo..."
      ENV["PHOTON_SUDO_REEXEC"] = "1"

      preserve = %w[
        PHOTON_ROOT PHOTON_STATE_ROOT PHOTON_DISABLE_SHIMS PHOTON_NO_SUDO
        PHOTON_FORCE_OVERWRITE PHOTON_DEBUG PHOTON_WARNINGS PHOTON_REPO_URLS
        PHOTON_NUCLEI_PATHS PHOTON_ALLOW_INSECURE PHOTON_ALLOW_DUPLICATES
      ].join(",")

      exec("sudo", "--preserve-env=#{preserve}", File.expand_path($PROGRAM_NAME), *ARGV)
    end

    def ensure_admin_paths!
      path_parts = ENV["PATH"].to_s.split(":")
      extras = %w[/usr/sbin /sbin /usr/local/sbin].reject { |dir| path_parts.include?(dir) }
      ENV["PATH"] = (extras + path_parts).uniq.join(":") unless extras.empty?
    end

    def parse_global_flags!(args)
      copy = args.dup
      args.clear

      index = 0
      while index < copy.length
        arg = copy[index]

        case arg
        when "--quiet", "-q", "--silent"
          @options[:verbose] = false
          @options[:quiet] = true
          Photon::Env.set_output_mode!(:quiet)
        when "--verbose", "-v"
          @options[:verbose] = true
          @options[:quiet] = false
          Photon::Env.set_output_mode!(:verbose)
        when "--pretend", "-p"
          @options[:pretend] = true
        when "--ask", "-a"
          @options[:ask] = true
        when "--yes", "-y"
          @options[:ask] = false
        when "--oneshot", "-1"
          @options[:oneshot] = true
        when "--nodeps", "-O"
          @options[:nodeps] = true
        when "--fetchonly", "-f"
          @options[:fetchonly] = true
        when "--resume"
          @options[:resume] = true
        when "--keep-going", "-k"
          @options[:keep_going] = true
        when "--debug"
          @options[:debug] = true
          Photon::Env.enable_debug!
        when "--warnings"
          @options[:warnings] = true
          Photon::Env.enable_warnings!
        when "--force"
          @options[:force] = true
          ENV["PHOTON_FORCE_OVERWRITE"] = "1"
        when "--jobs", "-j"
          value = copy[index + 1].to_s
          raise "Expected a numeric value after #{arg}" unless value.match?(/^\d+$/)

          @options[:jobs] = value.to_i
          ENV["PHOTON_JOBS"] = value
          index += 1
        else
          args << arg
        end

        index += 1
      end
    end

    def show_help
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}Photon Package Manager#{UI::COLORS[:reset]} #{UI::COLORS[:dim]}v#{VERSION}#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Portage-inspired source package manager with local + remote repo support#{UI::COLORS[:reset]}"
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}USAGE#{UI::COLORS[:reset]}"
      puts "  #{UI::COLORS[:cyan]}photon#{UI::COLORS[:reset]} [options] <command> [arguments]"
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}GLOBAL OPTIONS#{UI::COLORS[:reset]}"
      puts "  #{UI::COLORS[:green]}-q, --quiet#{UI::COLORS[:reset]}            Minimal output"
      puts "  #{UI::COLORS[:green]}-v, --verbose#{UI::COLORS[:reset]}          Full output #{UI::COLORS[:dim]}[default]#{UI::COLORS[:reset]}"
      puts "  #{UI::COLORS[:green]}-p, --pretend#{UI::COLORS[:reset]}          Show what would be done"
      puts "  #{UI::COLORS[:green]}-a, --ask#{UI::COLORS[:reset]}              Ask before proceeding #{UI::COLORS[:dim]}[default]#{UI::COLORS[:reset]}"
      puts "  #{UI::COLORS[:green]}-y, --yes#{UI::COLORS[:reset]}              Don't ask, just do it"
      puts "  #{UI::COLORS[:green]}-1, --oneshot#{UI::COLORS[:reset]}          Don't add to world"
      puts "  #{UI::COLORS[:green]}-O, --nodeps#{UI::COLORS[:reset]}           Skip dependency resolution"
      puts "  #{UI::COLORS[:green]}-f, --fetchonly#{UI::COLORS[:reset]}        Only fetch sources"
      puts "  #{UI::COLORS[:green]}-k, --keep-going#{UI::COLORS[:reset]}       Continue on failures"
      puts "  #{UI::COLORS[:green]}--resume#{UI::COLORS[:reset]}               Resume interrupted build"
      puts "  #{UI::COLORS[:green]}--force#{UI::COLORS[:reset]}                Force unmanaged overwrite only when supported"
      puts "  #{UI::COLORS[:green]}-j, --jobs N#{UI::COLORS[:reset]}            Parallel build jobs"
      puts "  #{UI::COLORS[:green]}--debug#{UI::COLORS[:reset]}                Full stack traces + extra logs"
      puts "  #{UI::COLORS[:green]}--warnings#{UI::COLORS[:reset]}             Show compiler warnings"
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}COMMANDS#{UI::COLORS[:reset]}"
      puts "  #{UI::COLORS[:cyan]}install, emerge#{UI::COLORS[:reset]}       Install packages"
      puts "  #{UI::COLORS[:cyan]}remove, unmerge#{UI::COLORS[:reset]}       Remove packages"
      puts "  #{UI::COLORS[:cyan]}search#{UI::COLORS[:reset]}                Search for packages"
      puts "  #{UI::COLORS[:cyan]}list, qlist#{UI::COLORS[:reset]}          List installed packages"
      puts "  #{UI::COLORS[:cyan]}info, metadata#{UI::COLORS[:reset]}       Show package info"
      puts "  #{UI::COLORS[:cyan]}files <pkg>#{UI::COLORS[:reset]}           Show installed files"
      puts "  #{UI::COLORS[:cyan]}which <cmd>#{UI::COLORS[:reset]}           Which package provides a command"
      puts "  #{UI::COLORS[:cyan]}owner <path>#{UI::COLORS[:reset]}          Which package owns a file path"
      puts "  #{UI::COLORS[:cyan]}update, sync#{UI::COLORS[:reset]}         Refresh repository metadata"
      puts "  #{UI::COLORS[:cyan]}clean, eclean#{UI::COLORS[:reset]}        Clean cache"
      puts "  #{UI::COLORS[:cyan]}doctor#{UI::COLORS[:reset]}                System health check"
      puts "  #{UI::COLORS[:cyan]}paths#{UI::COLORS[:reset]}                 Show Photon paths"
      puts "  #{UI::COLORS[:cyan]}env#{UI::COLORS[:reset]}                   Print exports for shell"
      puts "  #{UI::COLORS[:cyan]}setup-path#{UI::COLORS[:reset]}            Install PATH integration"
      puts "  #{UI::COLORS[:cyan]}compact-db#{UI::COLORS[:reset]}            Vacuum SQLite DB"
      puts "  #{UI::COLORS[:cyan]}version#{UI::COLORS[:reset]}               Show version"
      puts Photon::Env.help_section
    end

    def install_packages(package_names)
      if package_names.empty?
        portage_msg("No packages specified", :error)
        puts "Usage: #{UI::COLORS[:cyan]}photon install <package>...#{UI::COLORS[:reset]}"
        exit 1
      end

      resolver = DependencyResolver.new(@repository, @database)
      all_packages = []

      if @options[:nodeps]
        package_names.each do |name|
          pkg = @repository.find_package(name)
          if pkg
            all_packages << pkg unless @database.installed?(pkg.name)
          else
            portage_msg("Package not found: #{name}", :error)
            suggest_packages(name)
            exit 1
          end
        end
      else
        package_names.each do |name|
          begin
            all_packages.concat(resolver.resolve(name))
          rescue => e
            portage_msg("Cannot resolve '#{name}': #{e.message}", :error)
            suggest_packages(name)
            exit 1
          end
        end
      end

      all_packages.uniq! { |pkg| pkg.atom }

      if all_packages.empty?
        puts
        portage_msg("No packages to install")
        return
      end

      puts
      puts "#{UI::COLORS[:bold]}These are the packages that would be merged, in order:#{UI::COLORS[:reset]}"
      puts

      all_packages.each do |pkg|
        marker = @database.installed?(pkg.name) ? "R" : "N"
        size = estimate_size(pkg)
        color = marker == "N" ? UI::COLORS[:bright_green] : UI::COLORS[:bright_blue]
        puts "#{color}[#{marker}bv]#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}#{pkg.atom}-#{pkg.version}#{UI::COLORS[:reset]} #{UI::COLORS[:dim]}[#{size}]#{UI::COLORS[:reset]}"
      end

      total_size = all_packages.sum { |pkg| estimate_size_bytes(pkg) }
      puts
      puts "#{UI::COLORS[:bold]}Total:#{UI::COLORS[:reset]} #{all_packages.length} package(s), Size of downloads: #{UI.format_bytes(total_size)}"

      if @options[:pretend]
        puts
        portage_msg("Pretend run (--pretend). Nothing was installed.", :warn)
        return
      end

      if @options[:ask] && !confirm?("Would you like to merge these packages?")
        puts
        portage_msg("Aborting", :warn)
        exit 0
      end

      if @options[:fetchonly]
        puts
        portage_msg("Fetching sources only (--fetchonly)")
        all_packages.each { |pkg| Builder.new(pkg, 1, 1, @options).fetch_only }
        return
      end

      successful = 0
      failed = []
      started_at = Time.now

      all_packages.each_with_index do |package, index|
        current = index + 1
        total = all_packages.length

        puts
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Emerging (#{current}/#{total}) #{package.atom}-#{package.version}#{UI::COLORS[:reset]}"

        begin
          pkg_started_at = Time.now
          builder = Builder.new(package, current, total, @options)
          dest_dir = builder.build

          installer = Installer.new(package, @database, options: @options)
          installer.install(dest_dir)

          @database.world_add(package.atom) unless @options[:oneshot]
          PathIntegration.sync!(@database)

          successful += 1
          puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Successfully merged #{package.atom}-#{package.version} #{UI::COLORS[:dim]}(#{format_time(Time.now - pkg_started_at)})#{UI::COLORS[:reset]}"
        rescue => e
          failed << package.atom
          puts "#{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} #{UI::COLORS[:red]}Failed to emerge #{package.atom}: #{e.message}#{UI::COLORS[:reset]}"
          next if @options[:keep_going]
          break unless confirm?("Continue with remaining packages?", default_yes: false)
        end
      end

      puts
      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Jobs:#{UI::COLORS[:reset]} #{successful} succeeded" if successful.positive?

      if failed.any?
        puts "#{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Jobs:#{UI::COLORS[:reset]} #{failed.length} failed: #{failed.join(', ')}"
        exit 1
      end

      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Total time:#{UI::COLORS[:reset]} #{format_time(Time.now - started_at)}"
      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Done."
    end

    def remove_packages(package_names)
      if package_names.empty?
        portage_msg("No packages specified", :error)
        puts "Usage: #{UI::COLORS[:cyan]}photon remove <package>...#{UI::COLORS[:reset]}"
        exit 1
      end

      resolved_names = package_names.map { |name| @repository.normalize_name(name) }
      to_remove = resolved_names.select do |name|
        if @database.installed?(name)
          true
        else
          portage_msg("Package '#{name}' is not installed", :warn)
          false
        end
      end

      if to_remove.empty?
        puts "Nothing to do."
        return
      end

      puts
      puts "#{UI::COLORS[:bold]}These are the packages that would be unmerged:#{UI::COLORS[:reset]}"
      puts

      to_remove.each do |name|
        pkg = @database.get_package(name)
        atom = pkg[:atom] || name
        version = pkg[:version] || "?"
        puts "#{UI::COLORS[:red]}[uninstall]#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}#{atom}-#{version}#{UI::COLORS[:reset]}"
      end

      puts
      puts "#{UI::COLORS[:bold]}Total:#{UI::COLORS[:reset]} #{to_remove.length} package(s)"

      if @options[:ask] && !confirm?("Would you like to unmerge these packages?")
        puts
        portage_msg("Aborting", :warn)
        exit 0
      end

      puts
      to_remove.each do |name|
        info = @database.get_package(name)
        next unless info

        package = Package.new(name)
        package.version = info[:version] || "?"
        package.category = info[:metadata].dig(:category) || info[:category] || "app"

        puts "#{UI::COLORS[:yellow]}>>>#{UI::COLORS[:reset]} Unmerging #{info[:atom] || name}-#{package.version}..."

        begin
          Installer.new(package, @database, options: @options).uninstall
          PathIntegration.sync!(@database)
          puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Successfully unmerged #{info[:atom] || name}"
        rescue => e
          portage_msg("Failed to unmerge #{info[:atom] || name}: #{e.message}", :error)
        end
      end

      puts
      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Unmerge complete: #{to_remove.length} package(s) removed"
    end

    def search_packages(terms)
      atoms = @repository.list_atoms
      if atoms.empty?
        portage_msg("No packages available", :warn)
        puts "Repository sources checked:"
        @repository.source_overview.each do |source|
          puts "  #{UI::COLORS[:dim]}#{source[:type]}: #{source[:location]}#{UI::COLORS[:reset]}"
        end
        return
      end

      results = if terms.empty?
        atoms
      else
        query = terms.join(" ")
        pattern = Regexp.new(Regexp.escape(query).gsub("\\ ", ".*"), Regexp::IGNORECASE)

        atoms.select do |atom|
          pkg = @repository.find_package(atom)
          next false unless pkg
          [pkg.atom, pkg.description, pkg.category, pkg.name].compact.any? { |value| value.to_s.match?(pattern) }
        end
      end

      if results.empty?
        portage_msg("No matches found", :warn)
        suggest_packages(terms.join(" "))
        return
      end

      puts
      results.sort.each do |atom|
        pkg = @repository.find_package(atom)
        next unless pkg

        installed = @database.installed?(pkg.name)
        marker = installed ? "#{UI::COLORS[:green]}[I]#{UI::COLORS[:reset]}" : "#{UI::COLORS[:dim]}[ ]#{UI::COLORS[:reset]}"
        puts "#{marker} #{UI::COLORS[:bold]}#{pkg.atom}#{UI::COLORS[:reset]}"
        puts "      Latest version available: #{UI::COLORS[:bright_cyan]}#{pkg.version}#{UI::COLORS[:reset]}"
        unless pkg.description.to_s.empty?
          desc = pkg.description.to_s
          desc = desc[0..65] + "..." if desc.length > 68
          puts "      #{UI::COLORS[:dim]}#{desc}#{UI::COLORS[:reset]}"
        end
        puts
      end

      puts "#{UI::COLORS[:dim]}Found #{results.length} package(s)#{UI::COLORS[:reset]}"
    end

    def list_installed
      packages = @database.list_packages
      if packages.empty?
        portage_msg("No packages installed", :warn)
        puts "Install packages with: #{UI::COLORS[:cyan]}photon install <package>#{UI::COLORS[:reset]}"
        return
      end

      puts
      packages.each do |name|
        pkg = @database.get_package(name)
        next unless pkg
        puts "#{UI::COLORS[:bold]}#{pkg[:atom] || name}-#{pkg[:version]}#{UI::COLORS[:reset]}"
      end
      puts
      puts "#{UI::COLORS[:dim]}Total: #{packages.length} package(s)#{UI::COLORS[:reset]}"
    end

    def show_package_info(name)
      unless name
        portage_msg("No package specified", :error)
        puts "Usage: #{UI::COLORS[:cyan]}photon info <package>#{UI::COLORS[:reset]}"
        exit 1
      end

      pkg = @repository.find_package(name)
      unless pkg
        portage_msg("Package '#{name}' not found", :error)
        suggest_packages(name)
        exit 1
      end

      installed = @database.installed?(pkg.name)
      db_info = installed ? @database.get_package(pkg.name) : nil

      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}#{pkg.atom}-#{pkg.version}#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}#{'─' * 70}#{UI::COLORS[:reset]}"

      [
        ["Description", pkg.description],
        ["Homepage", pkg.homepage],
        ["License", pkg.license],
        ["Build system", pkg.build_system.to_s]
      ].each do |label, value|
        next if value.to_s.strip.empty?
        puts "  #{UI::COLORS[:bold]}#{label.ljust(12)}#{UI::COLORS[:reset]} #{value}"
      end

      puts "  #{UI::COLORS[:bold]}#{'Defined in'.ljust(12)}#{UI::COLORS[:reset]} #{@repository.package_source(pkg.atom) || '(unknown)'}"

      if installed && db_info
        install_time = Time.at(db_info[:installed_at]).strftime("%a %b %d %H:%M:%S %Y") rescue "unknown"
        puts "  #{UI::COLORS[:bold]}#{'Installed'.ljust(12)}#{UI::COLORS[:reset]} #{UI::COLORS[:green]}#{install_time}#{UI::COLORS[:reset]}"
        puts "  #{UI::COLORS[:bold]}#{'Files'.ljust(12)}#{UI::COLORS[:reset]} #{db_info[:files].length}"
      else
        puts "  #{UI::COLORS[:bold]}#{'Installed'.ljust(12)}#{UI::COLORS[:reset]} #{UI::COLORS[:red]}No#{UI::COLORS[:reset]}"
      end

      unless Array(pkg.dependencies).empty?
        puts
        puts "  #{UI::COLORS[:bold]}Runtime Dependencies:#{UI::COLORS[:reset]}"
        Array(pkg.dependencies).each do |dep|
          dep_name = @repository.normalize_name(dep)
          status = @database.installed?(dep_name) ? "#{UI::COLORS[:green]}✓#{UI::COLORS[:reset]}" : "#{UI::COLORS[:red]}✗#{UI::COLORS[:reset]}"
          puts "    #{status} #{dep}"
        end
      end

      unless Array(pkg.build_dependencies).empty?
        puts
        puts "  #{UI::COLORS[:bold]}Build Dependencies:#{UI::COLORS[:reset]}"
        Array(pkg.build_dependencies).each { |dep| puts "    • #{dep}" }
      end

      unless Array(pkg.host_tools).empty?
        puts
        puts "  #{UI::COLORS[:bold]}Host Tools:#{UI::COLORS[:reset]}"
        Array(pkg.host_tools).each { |tool| puts "    • #{tool}" }
      end

      puts
    end

    def show_package_files(name)
      unless name
        portage_msg("No package specified", :error)
        puts "Usage: photon files <package>"
        exit 1
      end

      pkg = @database.get_package(name)
      unless pkg
        portage_msg("Not installed: #{name}", :error)
        exit 1
      end

      puts
      puts "#{UI::COLORS[:bold]}Files owned by #{pkg[:atom] || pkg[:name]}-#{pkg[:version]}#{UI::COLORS[:reset]}"
      puts
      pkg[:files].sort.each { |file| puts "  #{file}" }
      puts
    end

    def which_command(cmd)
      unless cmd && !cmd.strip.empty?
        portage_msg("No command specified", :error)
        puts "Usage: photon which <cmd>"
        exit 1
      end

      who = @database.which_command(cmd.strip)
      if who
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{cmd} is provided by #{UI::COLORS[:bold]}#{who[:atom]}#{UI::COLORS[:reset]} (#{who[:path]})"
      else
        portage_msg("No package provides '#{cmd}'", :warn)
      end
    end

    def owner_of_path(path)
      unless path && !path.strip.empty?
        portage_msg("No path specified", :error)
        puts "Usage: photon owner <path>"
        exit 1
      end

      who = @database.owner_of(path.strip)
      if who
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{path} is owned by #{UI::COLORS[:bold]}#{who[:atom]}#{UI::COLORS[:reset]}"
      else
        portage_msg("No owner found for #{path}", :warn)
      end
    end

    def update_repository
      portage_msg("Refreshing repository metadata")
      count = @repository.update
      portage_msg("Repository ready: #{count} packages available")
    end

    def upgrade_packages
      installed = @database.list_packages
      if installed.empty?
        portage_msg("No packages installed", :warn)
        return
      end

      portage_msg("Upgrade functionality is not implemented yet", :warn)
      puts
      installed.first(10).each { |pkg| puts "  • #{pkg}" }
      puts "  ..." if installed.length > 10
    end

    def clean_cache
      portage_msg("Cleaning cache")
      total = 0

      @database.cache_dirs.each do |dir|
        next unless Dir.exist?(dir)
        total += dir_size(dir)
        FileUtils.rm_rf(dir)
      end

      if total.positive?
        portage_msg("Cleaned #{UI.format_bytes(total)}")
      else
        puts "Cache already clean"
      end
    end

    def run_doctor
      script = File.expand_path("../tools/photon_doctor.rb", __dir__)
      exec(RbConfig.ruby, script)
    end

    def debug_info
      portage_msg("Debug Information")
      puts
      puts "#{UI::COLORS[:bold]}Directories:#{UI::COLORS[:reset]}"
      puts "  Current:      #{Dir.pwd}"
      puts "  Install root: #{Database::PHOTON_ROOT}"
      puts "  State root:   #{Database::STATE_ROOT}"
      puts "  Database:     #{Database::DB_PATH}"
      puts "  Shims:        #{PathIntegration.shim_dir}"
      puts
      puts "#{UI::COLORS[:bold]}Repository sources:#{UI::COLORS[:reset]}"
      @repository.source_overview.each do |source|
        puts "  [#{source[:type]}] #{source[:location]}"
      end
      puts
      puts "#{UI::COLORS[:bold]}Statistics:#{UI::COLORS[:reset]}"
      puts "  Available packages: #{@repository.list_atoms.length}"
      puts "  Installed packages: #{@database.list_packages.length}"
      puts "  Ruby version:       #{RUBY_VERSION}"
      puts "  Photon version:     #{VERSION}"
      puts
      puts "#{UI::COLORS[:bold]}Environment:#{UI::COLORS[:reset]}"
      Photon::Env.dump_lines.each { |line| puts "  #{line}" }
      puts
    end

    def show_version
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}Photon Package Manager#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Version #{VERSION}#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Ruby #{RUBY_VERSION}#{UI::COLORS[:reset]}"
      puts
    end

    def show_paths
      puts
      puts "#{UI::COLORS[:bold]}Photon Paths#{UI::COLORS[:reset]}"
      puts
      puts "  Install root: #{UI::COLORS[:cyan]}#{Database::PHOTON_ROOT}#{UI::COLORS[:reset]}"
      puts "  State root:   #{UI::COLORS[:cyan]}#{Database::STATE_ROOT}#{UI::COLORS[:reset]}"
      puts "  Database:     #{UI::COLORS[:cyan]}#{Database::DB_PATH}#{UI::COLORS[:reset]}"
      puts "  Shims:        #{UI::COLORS[:cyan]}#{PathIntegration.shim_dir}#{UI::COLORS[:reset]}"
      puts
    end

    def print_env
      puts "export PHOTON_ROOT=#{shell_escape(Database::PHOTON_ROOT)}"
      puts "export PHOTON_STATE_ROOT=#{shell_escape(Database::STATE_ROOT)}"
    end

    def setup_path
      PathIntegration.setup_path!
      portage_msg("PATH integration installed!")
      puts "#{UI::COLORS[:dim]}(Restart your shell or source your rc file.)#{UI::COLORS[:reset]}"
    end

    def compact_db
      portage_msg("Compacting database")
      @database.compact!
      stats = @database.stats
      portage_msg("DB compact complete (pages=#{stats[:page_count]} free=#{stats[:freelist_count]})")
    end

    def portage_msg(message, type = :info)
      case type
      when :error
        puts "#{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} #{UI::COLORS[:red]}#{message}#{UI::COLORS[:reset]}"
      when :warn
        puts "#{UI::COLORS[:yellow]}>>>#{UI::COLORS[:reset]} #{message}"
      else
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{message}"
      end
    end

    def suggest_packages(search_term)
      atoms = @repository.list_atoms
      return if atoms.empty?

      normalized = search_term.to_s.downcase
      suggestions = atoms.select do |atom|
        atom.downcase.include?(normalized) || levenshtein_distance(atom.downcase, normalized) <= 2
      end

      puts
      if suggestions.any?
        puts "#{UI::COLORS[:bold]}Did you mean:#{UI::COLORS[:reset]}"
        suggestions.first(7).each { |atom| puts "  #{UI::COLORS[:cyan]}#{atom}#{UI::COLORS[:reset]}" }
      else
        puts "#{UI::COLORS[:bold]}Available packages:#{UI::COLORS[:reset]}"
        atoms.first(10).each { |atom| puts "  #{atom}" }
        puts "  #{UI::COLORS[:dim]}...#{UI::COLORS[:reset]}" if atoms.length > 10
      end
    end

    def confirm?(message, default_yes: true)
      return true unless @options[:ask]

      suffix = default_yes ? "[Y/n]" : "[y/N]"
      print "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{message} #{UI::COLORS[:dim]}#{suffix}#{UI::COLORS[:reset]} "
      answer = $stdin.gets.to_s.strip.downcase
      return default_yes if answer.empty?

      answer.start_with?("y")
    end

    def command_exists?(name)
      system(%Q{command -v "#{name}" >/dev/null 2>&1})
    end

    def levenshtein_distance(a, b)
      m = a.length
      n = b.length
      return m if n.zero?
      return n if m.zero?

      d = Array.new(m + 1) { Array.new(n + 1) }
      (0..m).each { |i| d[i][0] = i }
      (0..n).each { |j| d[0][j] = j }

      (1..n).each do |j|
        (1..m).each do |i|
          d[i][j] = if a[i - 1] == b[j - 1]
                      d[i - 1][j - 1]
                    else
                      [d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + 1].min
                    end
        end
      end

      d[m][n]
    end

    def estimate_size(package)
      case package.name
      when /vim|emacs|nano/ then "2-5 MB"
      when /gcc|llvm|rust|go/ then "50-100 MB"
      when /fastfetch|neofetch/ then "100-500 KB"
      when /kernel|linux/ then "500+ MB"
      when /python|ruby|perl/ then "10-20 MB"
      else "1-5 MB"
      end
    end

    def estimate_size_bytes(package)
      case package.name
      when /vim|emacs|nano/ then 3 * 1024 * 1024
      when /gcc|llvm|rust|go/ then 75 * 1024 * 1024
      when /fastfetch|neofetch/ then 300 * 1024
      when /kernel|linux/ then 500 * 1024 * 1024
      when /python|ruby|perl/ then 15 * 1024 * 1024
      else 2 * 1024 * 1024
      end
    end

    def format_time(seconds)
      if seconds < 60
        "#{seconds.round}s"
      elsif seconds < 3600
        minutes = (seconds / 60).floor
        secs = (seconds % 60).round
        "#{minutes}m #{secs}s"
      else
        hours = (seconds / 3600).floor
        minutes = ((seconds % 3600) / 60).floor
        "#{hours}h #{minutes}m"
      end
    end

    def dir_size(path)
      size = 0
      Find.find(path) { |file| size += File.size(file) if File.file?(file) }
      size
    rescue
      0
    end

    def shell_escape(value)
      value.to_s.gsub("'", %q('"'"'))
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  Photon::CLI.new.run(ARGV)
end
