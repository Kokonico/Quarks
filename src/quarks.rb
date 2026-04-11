#!/usr/bin/env ruby
# frozen_string_literal: true

require "find"
require "fileutils"

if ENV["QUARKS_TRACE_SYSTEM"] == "1"
  module Kernel
    alias __quarks_system system

    def system(*args)
      warn "QUARKS_TRACE system(#{args.map(&:inspect).join(', ')})\n  from: #{caller(1, 5).join("\n        ")}"
      __quarks_system(*args)
    end
  end
end

QUARKS_LIB_DIR = File.expand_path("../src", __dir__)
$LOAD_PATH.unshift(QUARKS_LIB_DIR) unless $LOAD_PATH.include?(QUARKS_LIB_DIR)

require "quarks/ui"
require "quarks/config"
require "quarks/env"
require "quarks/env"
require "quarks/package"
require "quarks/database"
require "quarks/repository"
require "quarks/web_repo"
require "quarks/resolver"
require "quarks/builder"
require "quarks/installer"
require "quarks/path_integration"
require "quarks/system_integration"
require "quarks/parallel_build"
require "quarks/systemd_manager"
require "quarks/signal_handler"
require "quarks/use_slots"
require "quarks/smart_resolver"
require "quarks/sandbox_build"
require "quarks/core"
require "quarks/query"

module Quarks
  VERSION = "1.4.0"
  AUTHOR  = "Quarks Developers"

  class CLI
    ROOT_COMMANDS = %w[
      install i emerge
      remove uninstall r rm unmerge
      upgrade up world
      clean eclean
      compact-db
      setup-path
    ].freeze

    ADMIN_COMMANDS = %w[
      add-repo remove-repo list-repos
      enable-service disable-service
    ].freeze

    def initialize
      setup_signal_handling!
      ensure_admin_paths!

      @database = Database.new
      @repository = Repository.new
      @use_config = USEConfig.new
      @emerge_queue = EmergeQueue.new
      @logger = EmergeLogger.new
      @build_state_manager = BuildStateManager.new
      @world_manager = WorldManager.new

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
        jobs: Quarks::Env.jobs,
        force: false,
        debug: false,
        warnings: false,
        update_world: false,
        newuse: false,
        changed_use: false,
        depclean: false
      }
    end

    def setup_signal_handling!
      Quarks::SignalHandler.instance.setup!

      Quarks::SignalHandler.instance.on_signal("INT") do
        if Quarks::SignalHandler.instance.interrupted?
          puts "\n#{UI::COLORS[:yellow]}>>> Interrupt received, saving state...#{UI::COLORS[:reset]}"
          save_emerge_state!
          puts "#{UI::COLORS[:yellow]}>>> State saved. Run with --resume to continue.#{UI::COLORS[:reset]}"
          exit 130
        end
      end

      Quarks::SignalHandler.instance.register_state_saver do
        save_emerge_state!
      end
    end

    def save_emerge_state!
      return if @emerge_queue.nil?

      @emerge_queue.save
      @build_state_manager.save_state(@build_state_manager.current_state)
    end

    def check_resume!
      return unless @options[:resume]

      saved_state = @build_state_manager.load_state
      if saved_state
        puts "#{UI::COLORS[:green]}>>> Resuming from saved state...#{UI::COLORS[:reset]}"
        if saved_state["package"]
          puts "  Previous package: #{saved_state['package']}"
        end
        return true
      end

      queue_state = @emerge_queue.load
      if queue_state && queue_state["packages"]
        puts "#{UI::COLORS[:green]}>>> Resuming emerge queue...#{UI::COLORS[:reset]}"
        puts "  Packages: #{queue_state['progress']['done']}/#{queue_state['progress']['total']}"
        return true
      end

      puts "#{UI::COLORS[:yellow]}>>> No saved state found#{UI::COLORS[:reset]}"
      false
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
      when "add-repo" then add_repository(args)
      when "remove-repo" then remove_repository(args)
      when "list-repos" then list_repositories
      when "enable-service" then enable_service(args.first)
      when "disable-service" then disable_service(args.first)
      when "use" then manage_use(args)
      when "world" then show_world
      when "depclean" then depclean_packages
      when "preserved-rebuild" then preserved_rebuild
      when "check-world" then check_world
      when "query" then run_query(args)
      when "q" then run_query(args)
      when "hold" then hold_package(args)
      when "release" then release_package(args)
      when "flag" then flag_package(args)
      when "build" then set_build(args)
      when "profile" then manage_profiles(args)
      when "hook" then manage_hooks(args)
      when "status" then show_status
      when "sync" then set_sync(args)
      else
        UI.error "Unknown command: #{command}"
        puts "Run #{UI::COLORS[:cyan]}quarks help#{UI::COLORS[:reset]} for usage information."
        exit 1
      end
    rescue Interrupt
      puts
      portage_msg("Interrupted by user", :warn)
      exit 130
    rescue => e
      portage_msg(e.message, :error)

      if @options[:debug] || Quarks::Env.debug?
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
      return if ENV["QUARKS_SUDO_REEXEC"] == "1"
      return if ENV["QUARKS_NO_SUDO"] == "1"

      install_root = Database::QUARKS_ROOT
      writable = File.writable?(install_root) || (!File.exist?(install_root) && File.writable?(File.dirname(install_root)))
      return if writable

      unless command_exists?("sudo")
        raise <<~MSG.strip
          Insufficient permissions!

          This command needs root access because your install root is:

            #{install_root}

          Fix options:
            1) Run with sudo:
                 sudo quarks #{ARGV.join(' ')}

            2) Or switch to a user install root with QUARKS_ROOT.
        MSG
      end

      puts "#{UI::COLORS[:yellow]}>>>#{UI::COLORS[:reset]} Elevated permissions required for '#{command}'. Re-running with sudo..."
      ENV["QUARKS_SUDO_REEXEC"] = "1"

      preserve = %w[
        QUARKS_ROOT QUARKS_STATE_ROOT QUARKS_DISABLE_SHIMS QUARKS_NO_SUDO
        QUARKS_FORCE_OVERWRITE QUARKS_DEBUG QUARKS_WARNINGS QUARKS_REPO_URLS
        QUARKS_NUCLEI_PATHS QUARKS_ALLOW_INSECURE QUARKS_ALLOW_DUPLICATES
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
          Quarks::Env.set_output_mode!(:quiet)
        when "--verbose", "-v"
          @options[:verbose] = true
          @options[:quiet] = false
          Quarks::Env.set_output_mode!(:verbose)
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
          Quarks::Env.enable_debug!
        when "--warnings"
          @options[:warnings] = true
          Quarks::Env.enable_warnings!
        when "--force"
          @options[:force] = true
          ENV["QUARKS_FORCE_OVERWRITE"] = "1"
        when "--jobs", "-j"
          value = copy[index + 1].to_s
          raise "Expected a numeric value after #{arg}" unless value.match?(/^\d+$/)

          @options[:jobs] = value.to_i
          ENV["QUARKS_JOBS"] = value
          index += 1
        else
          args << arg
        end

        index += 1
      end
    end

    def show_help
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}Quarks Package Manager#{UI::COLORS[:reset]} #{UI::COLORS[:dim]}v#{VERSION}#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Portage-inspired source package manager with local + remote repo support#{UI::COLORS[:reset]}"
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}USAGE#{UI::COLORS[:reset]}"
      puts "  #{UI::COLORS[:cyan]}quarks#{UI::COLORS[:reset]} [options] <command> [arguments]"
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
      puts "  #{UI::COLORS[:green]}-j, --jobs N#{UI::COLORS[:reset]}           Parallel build jobs"
      puts "  #{UI::COLORS[:green]}--debug#{UI::COLORS[:reset]}                Full stack traces + extra logs"
      puts "  #{UI::COLORS[:green]}--warnings#{UI::COLORS[:reset]}             Show compiler warnings"
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}COMMANDS#{UI::COLORS[:reset]}"
      puts "  #{UI::COLORS[:cyan]}install, emerge#{UI::COLORS[:reset]}       Install packages"
      puts "  #{UI::COLORS[:cyan]}remove, unmerge#{UI::COLORS[:reset]}       Remove packages"
      puts "  #{UI::COLORS[:cyan]}search#{UI::COLORS[:reset]}                Search for packages"
      puts "  #{UI::COLORS[:cyan]}list, qlist#{UI::COLORS[:reset]}           List installed packages"
      puts "  #{UI::COLORS[:cyan]}info, metadata#{UI::COLORS[:reset]}        Show package info"
      puts "  #{UI::COLORS[:cyan]}files <pkg>#{UI::COLORS[:reset]}           Show installed files"
      puts "  #{UI::COLORS[:cyan]}which <cmd>#{UI::COLORS[:reset]}           Which package provides a command"
      puts "  #{UI::COLORS[:cyan]}owner <path>#{UI::COLORS[:reset]}          Which package owns a file path"
      puts "  #{UI::COLORS[:cyan]}update, sync#{UI::COLORS[:reset]}          Refresh repository metadata"
      puts "  #{UI::COLORS[:cyan]}upgrade, world#{UI::COLORS[:reset]}        Upgrade installed packages"
      puts "  #{UI::COLORS[:cyan]}clean, eclean#{UI::COLORS[:reset]}         Clean cache"
      puts "  #{UI::COLORS[:cyan]}doctor#{UI::COLORS[:reset]}                System health check"
      puts "  #{UI::COLORS[:cyan]}paths#{UI::COLORS[:reset]}                 Show Quarks paths"
      puts "  #{UI::COLORS[:cyan]}env#{UI::COLORS[:reset]}                   Print exports for shell"
      puts "  #{UI::COLORS[:cyan]}setup-path#{UI::COLORS[:reset]}            Install PATH integration"
      puts "  #{UI::COLORS[:cyan]}compact-db#{UI::COLORS[:reset]}            Vacuum SQLite DB"
      puts "  #{UI::COLORS[:cyan]}add-repo#{UI::COLORS[:reset]}              Add web repository"
      puts "  #{UI::COLORS[:cyan]}remove-repo#{UI::COLORS[:reset]}           Remove web repository"
      puts "  #{UI::COLORS[:cyan]}list-repos#{UI::COLORS[:reset]}            List configured repositories"
      puts "  #{UI::COLORS[:cyan]}enable-service#{UI::COLORS[:reset]}        Enable systemd service"
      puts "  #{UI::COLORS[:cyan]}disable-service#{UI::COLORS[:reset]}       Disable systemd service"
      puts "  #{UI::COLORS[:cyan]}use#{UI::COLORS[:reset]}                   Manage USE flags"
      puts "  #{UI::COLORS[:cyan]}world#{UI::COLORS[:reset]}                 Show world file contents"
      puts "  #{UI::COLORS[:cyan]}depclean#{UI::COLORS[:reset]}              Remove unused packages"
      puts "  #{UI::COLORS[:cyan]}check-world#{UI::COLORS[:reset]}           Check world file integrity"
      puts "  #{UI::COLORS[:cyan]}preserved-rebuild#{UI::COLORS[:reset]}     Rebuild for preserved libs"
      puts "  #{UI::COLORS[:cyan]}version#{UI::COLORS[:reset]}               Show version"
      puts
      puts "  #{UI::COLORS[:brand]}query, q#{UI::COLORS[:reset]}             Query package information"
      puts "  #{UI::COLORS[:brand]}hold#{UI::COLORS[:reset]} [pkg]           Hold/release packages"
      puts "  #{UI::COLORS[:brand]}flag#{UI::COLORS[:reset]} [pkg]           Flag package for attention"
      puts "  #{UI::COLORS[:brand]}build#{UI::COLORS[:reset]}                Set build configuration"
      puts "  #{UI::COLORS[:brand]}profile#{UI::COLORS[:reset]}              Profile management"
      puts "  #{UI::COLORS[:brand]}hook#{UI::COLORS[:reset]}                 Hook script management"
      puts "  #{UI::COLORS[:brand]}sync#{UI::COLORS[:reset]}                 Set sync mode"
      puts "  #{UI::COLORS[:brand]}status#{UI::COLORS[:reset]}               System status overview"
      puts Quarks::Env.help_section
    end

    def install_packages(package_names)
      if package_names.empty?
        portage_msg("No packages specified", :error)
        puts "Usage: #{UI::COLORS[:cyan]}quarks install <package>...#{UI::COLORS[:reset]}"
        exit 1
      end

      check_resume! if @options[:resume]

      resolver = SmartResolver.new(@repository, @database, use_config: @use_config)
      blocker_mgr = BlockerManager.new(@repository, @database)
      conflict_resolver = ConflictResolver.new(@repository, @database)
      slot_mgr = SLOTManager.new

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
            resolved = resolver.resolve(name)
            all_packages.concat(resolved)
          rescue SmartResolver::CircularDependencyError => e
            portage_msg("Circular dependency: #{e.cycle.join(' -> ')}", :error)
            exit 1
          rescue SmartResolver::MissingDependencyError => e
            portage_msg("Missing dependency: #{e.dependency}", :error)
            exit 1
          rescue SmartResolver::BlockedPackageError => e
            portage_msg("Blocked package: #{e.message}", :error)
            exit 1
          rescue => e
            portage_msg("Cannot resolve '#{name}': #{e.message}", :error)
            suggest_packages(name)
            exit 1
          end
        end
      end

      all_packages.uniq! { |pkg| pkg.atom }

      all_packages.each do |pkg|
        blockers = blocker_mgr.check_blockers(pkg)
        unless blockers.empty?
          blockers.each do |block|
            portage_msg("Blocker: #{block[:message]}", :error)
          end
          exit 1
        end
      end

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
        slot_info = pkg.slot ? ":#{pkg.slot}" : ""
        color = marker == "N" ? UI::COLORS[:bright_green] : UI::COLORS[:bright_blue]
        puts "#{color}[#{marker}#{slot_info}]#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}#{pkg.atom}-#{pkg.version}#{UI::COLORS[:reset]} #{UI::COLORS[:dim]}[#{size}]#{UI::COLORS[:reset]}"

        if pkg.blocks.any?
          puts "      #{UI::COLORS[:yellow]}blocks: #{pkg.blocks.join(', ')}#{UI::COLORS[:reset]}"
        end
      end

      total_size = all_packages.sum { |pkg| estimate_size_bytes(pkg) }
      puts
      puts "#{UI::COLORS[:bold]}Total:#{UI::COLORS[:reset]} #{all_packages.length} package(s), Size of downloads: #{UI.format_bytes(total_size)}"

      if @options[:pretend]
        puts
        portage_msg("Pretend run (--pretend). Nothing was installed.", :warn)

        if resolver.conflicts.any?
          puts
          puts "#{UI::COLORS[:red]}Issues found:#{UI::COLORS[:reset]}"
          resolver.conflicts.each do |c|
            puts "  - #{c[:type]}: #{c[:package]} - #{c[:dependency] || c[:blocker] || 'conflict'}"
          end
        end

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
      skipped = []
      started_at = Time.now

      all_packages.each_with_index do |package, index|
        SignalHandler.instance.check_and_raise!

        current = index + 1
        total = all_packages.length

        puts
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Emerging (#{current}/#{total}) #{package.atom}-#{package.version}#{UI::COLORS[:reset]}"

        if package.slot
          slot_mgr.register(package, package.slot)
        end

        @build_state_manager.save_state({
          "package" => package.to_h,
          "phase" => "building",
          "started_at" => Time.now.iso8601
        })

        pkg_started_at = Time.now
        begin
          builder = Builder.new(package, current, total, @options)
          dest_dir = builder.build

          installer = Installer.new(package, @database, options: @options)
          installer.install(dest_dir)

          unless @options[:oneshot]
            @database.world_add(package.atom)
            @world_manager.add(package.atom)
          end

          PathIntegration.sync!(@database)

          @logger.log_success(package, Time.now - pkg_started_at)
          successful += 1
          @emerge_queue.mark_complete(package.name)

          puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Successfully merged #{package.atom}-#{package.version} #{UI::COLORS[:dim]}(#{format_time(Time.now - pkg_started_at)})#{UI::COLORS[:reset]}"

        rescue Quarks::SignalHandler::InterruptedError
          puts "\n#{UI::COLORS[:yellow]}>>> Interrupted! State saved.#{UI::COLORS[:reset]}"
          save_emerge_state!
          exit 130

        rescue => e
          @logger.log_failure(package, e)
          failed << { atom: package.atom, error: e.message }
          @emerge_queue.mark_failed(package.name, error: e)
          puts "#{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} #{UI::COLORS[:red]}Failed to emerge #{package.atom}: #{e.message}#{UI::COLORS[:reset]}"

          if @options[:keep_going]
            skipped << package.atom
            next
          end

          break unless confirm?("Continue with remaining packages?", default_yes: false)
        end
      end

      puts
      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Jobs:#{UI::COLORS[:reset]} #{successful} succeeded"
      # check if integration installed
      puts "#{UI::COLORS[:dim]}Packages emerged: #{all_packages.length}, Success: #{successful}, Failed: #{failed.length}#{UI::COLORS[:reset]}"

      if failed.any?
        puts
        puts "#{UI::COLORS[:red]}Failed packages:#{UI::COLORS[:reset]}"
        failed.each do |f|
          puts "  #{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} #{f[:atom]}: #{f[:error]}"
        end
      end

      if skipped.any?
        puts
        puts "#{UI::COLORS[:yellow]}Skipped packages:#{UI::COLORS[:reset]}"
        skipped.each { |s| puts "  #{s}" }
      end

      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Total time:#{UI::COLORS[:reset]} #{format_time(Time.now - started_at)}"

      if failed.any? && !@options[:keep_going]
        exit 1
      end
    end

    def remove_packages(package_names)
      if package_names.empty?
        portage_msg("No packages specified", :error)
        puts "Usage: #{UI::COLORS[:cyan]}quarks remove <package>...#{UI::COLORS[:reset]}"
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
        puts "Install packages with: #{UI::COLORS[:cyan]}quarks install <package>#{UI::COLORS[:reset]}"
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
        puts "Usage: #{UI::COLORS[:cyan]}quarks info <package>#{UI::COLORS[:reset]}"
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
        puts "Usage: quarks files <package>"
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
        puts "Usage: quarks which <cmd>"
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
        puts "Usage: quarks owner <path>"
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
      if @options[:pretend]
        portage_msg("Performing a dry run upgrade check")
      else
        portage_msg("Starting system upgrade")
      end

      world_packages = @database.world_list
      if world_packages.empty?
        installed = @database.list_packages
        if installed.empty?
          portage_msg("No packages installed", :warn)
          return
        end
        portage_msg("World file empty, checking all installed packages for updates")
        @upgrade_targets = installed
      else
        @upgrade_targets = world_packages
      end

      updates_available = []
      up_to_date = []

      @upgrade_targets.each do |atom|
        pkg = @repository.find_package(atom)
        unless pkg
          up_to_date << { atom: atom, reason: "Not in repositories" }
          next
        end

        db_pkg = @database.get_package(pkg.name)
        if db_pkg
          if version_needs_update?(db_pkg[:version], pkg.version)
            updates_available << {
              atom: atom,
              current_version: db_pkg[:version],
              new_version: pkg.version,
              package: pkg
            }
          else
            up_to_date << { atom: atom, current_version: db_pkg[:version] }
          end
        else
          up_to_date << { atom: atom, reason: "Not installed via world" }
        end
      end

      puts
      if updates_available.empty?
        portage_msg("System is up to date!")
        if up_to_date.any? && !@options[:quiet]
          puts
          puts "#{UI::COLORS[:dim]}#{up_to_date.length} packages checked#{UI::COLORS[:reset]}"
        end
        return
      end

      puts "#{UI::COLORS[:bold]}The following packages will be upgraded:#{UI::COLORS[:reset]}"
      puts
      updates_available.each do |update|
        puts "#{UI::COLORS[:cyan]}#{update[:atom]}#{UI::COLORS[:reset]}"
        puts "  #{UI::COLORS[:dim]}#{update[:current_version]}#{UI::COLORS[:reset]} " \
             "#{UI::COLORS[:green]}->#{UI::COLORS[:reset]} " \
             "#{UI::COLORS[:bright_green]}#{update[:new_version]}#{UI::COLORS[:reset]}"
      end
      puts
      puts "#{UI::COLORS[:bold]}Total:#{UI::COLORS[:reset]} #{updates_available.length} package(s) to upgrade"

      if @options[:pretend]
        puts
        portage_msg("Pretend run (--pretend). Nothing was upgraded.", :warn)
        return
      end

      if @options[:ask] && !confirm?("Would you like to upgrade these packages?")
        puts
        portage_msg("Aborting upgrade", :warn)
        exit 0
      end

      resolver = DependencyResolver.new(@repository, @database)
      packages_to_build = []

      updates_available.each do |update|
        begin
          resolver.resolve(update[:package].name).each do |pkg|
            unless packages_to_build.any? { |p| p.name == pkg.name }
              packages_to_build << pkg
            end
          end
        rescue => e
          puts "#{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} Failed to resolve deps for #{update[:atom]}: #{e.message}"
          next if @options[:keep_going]
          break unless confirm?("Continue with remaining packages?", default_yes: false)
        end
      end

      packages_to_build.uniq! { |p| p.name }

      if packages_to_build.empty?
        puts
        portage_msg("No packages to build", :warn)
        return
      end

      puts
      puts "#{UI::COLORS[:bold]}Packages to emerge (including dependencies):#{UI::COLORS[:reset]}"
      packages_to_build.each do |pkg|
        marker = @database.installed?(pkg.name) ? "U" : "N"
        color = marker == "U" ? UI::COLORS[:bright_blue] : UI::COLORS[:bright_green]
        puts "#{color}[#{marker}bv]#{UI::COLORS[:reset]} #{pkg.atom}-#{pkg.version}"
      end
      puts

      if @options[:ask] && !confirm?("Proceed with emerging packages?")
        puts
        portage_msg("Aborting upgrade", :warn)
        exit 0
      end

      successful = 0
      failed = []
      started_at = Time.now

      packages_to_build.each_with_index do |package, index|
        current = index + 1
        total = packages_to_build.length

        puts
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Upgrading (#{current}/#{total}) #{package.atom}-#{package.version}#{UI::COLORS[:reset]}"

        begin
          pkg_started_at = Time.now
          builder = Builder.new(package, current, total, @options)
          dest_dir = builder.build

          installer = Installer.new(package, @database, options: @options)
          installer.install(dest_dir)

          PathIntegration.sync!(@database)

          successful += 1
          puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Successfully upgraded #{package.atom}-#{package.version} #{UI::COLORS[:dim]}(#{format_time(Time.now - pkg_started_at)})#{UI::COLORS[:reset]}"
        rescue => e
          failed << package.atom
          puts "#{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} #{UI::COLORS[:red]}Failed to upgrade #{package.atom}: #{e.message}#{UI::COLORS[:reset]}"
          next if @options[:keep_going]
          break unless confirm?("Continue with remaining packages?", default_yes: false)
        end
      end

      puts
      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Upgrade complete#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Packages: #{successful} succeeded" if successful.positive?
      puts "#{UI::COLORS[:dim]}Packages: #{failed.length} failed#{UI::COLORS[:reset]}" if failed.any?
      puts "#{UI::COLORS[:dim]}Time: #{format_time(Time.now - started_at)}#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}System: #{up_to_date.length} packages up to date#{UI::COLORS[:reset]}"

      if failed.any?
        exit 1
      end
    end

    def version_needs_update?(current, available)
      return true if current.nil? || current.empty?
      return true if available.nil? || available.empty?

      current_parts = parse_version(current)
      available_parts = parse_version(available)

      available_parts <=> current_parts
    end

    def parse_version(version)
      version.to_s.scan(/(\d+)|([a-zA-Z]+)/).flatten.compact.map do |part|
        if part =~ /^\d+$/
          part.to_i
        else
          part
        end
      end
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
      script = File.expand_path("../tools/quarks_doctor.rb", __dir__)
      exec(RbConfig.ruby, script)
    end

    def debug_info
      portage_msg("Debug Information")
      puts
      puts "#{UI::COLORS[:bold]}Directories:#{UI::COLORS[:reset]}"
      puts "  Current:      #{Dir.pwd}"
      puts "  Install root: #{Database::QUARKS_ROOT}"
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
      puts "  Quarks version:     #{VERSION}"
      puts
      puts "#{UI::COLORS[:bold]}Environment:#{UI::COLORS[:reset]}"
      Quarks::Env.dump_lines.each { |line| puts "  #{line}" }
      puts
    end

    def show_version
      puts
      puts "#{UI::COLORS[:bold]}#{UI::COLORS[:bright_cyan]}Quarks Package Manager#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Version #{VERSION}#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Ruby #{RUBY_VERSION}#{UI::COLORS[:reset]}"
      puts
    end

    def show_paths
      puts
      puts "#{UI::COLORS[:bold]}Quarks Paths#{UI::COLORS[:reset]}"
      puts
      puts "  Install root: #{UI::COLORS[:cyan]}#{Database::QUARKS_ROOT}#{UI::COLORS[:reset]}"
      puts "  State root:   #{UI::COLORS[:cyan]}#{Database::STATE_ROOT}#{UI::COLORS[:reset]}"
      puts "  Database:     #{UI::COLORS[:cyan]}#{Database::DB_PATH}#{UI::COLORS[:reset]}"
      puts "  Shims:        #{UI::COLORS[:cyan]}#{PathIntegration.shim_dir}#{UI::COLORS[:reset]}"
      puts
    end

    def print_env
      puts "export QUARKS_ROOT=#{shell_escape(Database::QUARKS_ROOT)}"
      puts "export QUARKS_STATE_ROOT=#{shell_escape(Database::STATE_ROOT)}"
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

    def add_repository(args)
      if args.length < 2
        puts "Usage: #{UI::COLORS[:cyan]}quarks add-repo <name> <url> [--priority N] [--gpg-key-id ID]#{UI::COLORS[:reset]}"
        puts
        puts "Options:"
        puts "  --priority N      Repository priority (lower = higher priority, default: 100)"
        puts "  --gpg-key-id ID  GPG key ID for signature verification"
        puts "  --gpg-key-url URL URL to download GPG key"
        exit 1
      end

      name = args[0]
      url = args[1]
      priority = 100
      gpg_key_id = nil
      gpg_key_url = nil

      args[2..].each_with_index do |arg, i|
        case arg
        when "--priority"
          priority = args[i + 3].to_i rescue 100
        when "--gpg-key-id"
          gpg_key_id = args[i + 3]
        when "--gpg-key-url"
          gpg_key_url = args[i + 3]
        end
      end

      unless url.start_with?("http://", "https://")
        UI.error "Repository URL must start with http:// or https://"
        exit 1
      end

      repo = Quarks::WebRepoManager.add_repo(
        name: name,
        url: url,
        priority: priority,
        gpg_key_id: gpg_key_id,
        gpg_key_url: gpg_key_url
      )

      puts
      portage_msg("Repository '#{name}' added successfully")
      puts "  URL: #{url}"
      puts "  Priority: #{priority}"
      puts "  GPG Key: #{gpg_key_id || 'not configured'}"

      if @options[:ask]
        puts
        if confirm?("Sync repository now?")
          sync_result = Quarks::WebRepoManager.sync_repo(name, force: true)
          if sync_result
            portage_msg("Repository synced successfully")
          else
            portage_msg("Repository sync failed", :warn)
          end
        end
      end
    end

    def remove_repository(args)
      if args.empty?
        puts "Usage: #{UI::COLORS[:cyan]}quarks remove-repo <name>...#{UI::COLORS[:reset]}"
        exit 1
      end

      args.each do |name|
        removed = Quarks::WebRepoManager.remove_repo(name)
        if removed
          puts "Removed repository: #{name}"
        else
          UI.error "Repository not found: #{name}"
        end
      end
    end

    def list_repositories
      repos = Quarks::WebRepoManager.load_repos

      if repos.empty?
        puts
        portage_msg("No web repositories configured")
        puts
        puts "Add repositories with:"
        puts "  #{UI::COLORS[:cyan]}quarks add-repo <name> <url>#{UI::COLORS[:reset]}"
        return
      end

      puts
      puts "#{UI::COLORS[:bold]}Configured Web Repositories#{UI::COLORS[:reset]}"
      puts

      sorted = repos.values.sort_by(&:priority)
      sorted.each do |repo|
        status = repo.enabled ? "#{UI::COLORS[:green]}enabled#{UI::COLORS[:reset]}" : "#{UI::COLORS[:dim]}disabled#{UI::COLORS[:reset]}"
        expiry = repo.expired? ? "#{UI::COLORS[:yellow]}(stale)#{UI::COLORS[:reset]}" : ""

        puts "#{UI::COLORS[:cyan]}#{repo.name}#{UI::COLORS[:reset]}"
        puts "  Priority: #{repo.priority}"
        puts "  URL: #{repo.repo_url}"
        puts "  Status: #{status} #{expiry}"
        if repo.last_sync
          puts "  Last sync: #{repo.last_sync.strftime("%Y-%m-%d %H:%M:%S")}"
        else
          puts "  Last sync: #{UI::COLORS[:dim]}never#{UI::COLORS[:reset]}"
        end
        if repo.gpg_key_id
          puts "  GPG Key: #{repo.gpg_key_id}"
        end
        puts
      end
    end

    def enable_service(name)
      unless name
        puts "Usage: #{UI::COLORS[:cyan]}quarks enable-service <service-name>#{UI::COLORS[:reset]}"
        exit 1
      end

      if Quarks::SystemdManager.enable_service(name, dry_run: @options[:pretend])
        portage_msg("Service '#{name}' enabled")
      else
        UI.error "Failed to enable service '#{name}'"
        exit 1
      end
    end

    def disable_service(name)
      unless name
        puts "Usage: #{UI::COLORS[:cyan]}quarks disable-service <service-name>#{UI::COLORS[:reset]}"
        exit 1
      end

      if Quarks::SystemdManager.disable_service(name, dry_run: @options[:pretend])
        portage_msg("Service '#{name}' disabled")
      else
        UI.error "Failed to disable service '#{name}'"
        exit 1
      end
    end

    def manage_use(args)
      if args.empty?
        show_use_flags
      elsif args[0] == "set"
        set_use_flags(args[1..-1])
      elsif args[0] == "del"
        remove_use_flags(args[1..-1])
      elsif args[0] == "package"
        set_package_use(args[1..-1])
      else
        puts "Usage:"
        puts "  #{UI::COLORS[:cyan]}quarks use#{UI::COLORS[:reset]}                 Show current USE flags"
        puts "  #{UI::COLORS[:cyan]}quarks use set <flags>...#{UI::COLORS[:reset]}  Set global USE flags"
        puts "  #{UI::COLORS[:cyan]}quarks use del <flags>...#{UI::COLORS[:reset]}  Remove global USE flags"
        puts "  #{UI::COLORS[:cyan]}quarks use package <pkg> <flags>#{UI::COLORS[:reset]} Set package-specific flags"
      end
    end

    def show_use_flags
      use_config = USEConfig.new

      puts
      puts "#{UI::COLORS[:bold]}Current USE flags#{UI::COLORS[:reset]}"
      puts

      system_flags = use_config.system_flags
      if system_flags.any?
        puts "#{UI::COLORS[:green]}System USE:#{UI::COLORS[:reset]}"
        puts "  #{system_flags.join(' ')}"
        puts
      end

      profile_flags = use_config.profile_flags
      if profile_flags.any?
        puts "#{UI::COLORS[:green]}Profile USE:#{UI::COLORS[:reset]}"
        puts "  #{profile_flags.join(' ')}"
        puts
      end

      env_flags = use_config.env_flags
      if env_flags.any?
        puts "#{UI::COLORS[:green]}Environment USE:#{UI::COLORS[:reset]}"
        puts "  #{env_flags.join(' ')}"
        puts
      end

      user_flags = use_config.flags
      if user_flags.any?
        puts "#{UI::COLORS[:green]}User USE:#{UI::COLORS[:reset]}"
        puts "  #{user_flags.join(' ')}"
        puts
      end

      all_flags = use_config.all_flags
      puts "#{UI::COLORS[:bold]}All active USE flags:#{UI::COLORS[:reset]}"
      puts "  #{all_flags.join(' ')}"
      puts
    end

    def set_use_flags(flags)
      use_config = USEConfig.new
      flags.each { |f| use_config.add_flag(f) }
      use_config.save!
      portage_msg("USE flags updated")
      show_use_flags
    end

    def remove_use_flags(flags)
      use_config = USEConfig.new
      flags.each { |f| use_config.remove_flag(f) }
      use_config.save!
      portage_msg("USE flags updated")
      show_use_flags
    end

    def set_package_use(args)
      if args.length < 2
        UI.error "Usage: quarks use package <package> <flags...>"
        exit 1
      end

      package = args[0]
      flags = args[1..-1]

      use_config = USEConfig.new
      use_config.set_package_flags(package, flags)
      use_config.save!
      portage_msg("Package USE flags set for #{package}: #{flags.join(' ')}")
    end

    def show_world
      world = WorldManager.new
      packages = world.contents

      if packages.empty?
        puts
        portage_msg("World file is empty")
        return
      end

      puts
      puts "#{UI::COLORS[:bold]}World file packages#{UI::COLORS[:reset]}"
      puts

      packages.each do |atom|
        pkg = @repository.find_package(atom)
        if pkg
          installed = @database.installed?(pkg.name)
          status = installed ? "#{UI::COLORS[:green]}installed#{UI::COLORS[:reset]}" : "#{UI::COLORS[:yellow]}not installed#{UI::COLORS[:reset]}"
          puts "  #{UI::COLORS[:cyan]}#{atom}#{UI::COLORS[:reset]} - #{status}"
        else
          puts "  #{UI::COLORS[:dim]}#{atom}#{UI::COLORS[:reset]} - #{UI::COLORS[:red]}not in repositories#{UI::COLORS[:reset]}"
        end
      end

      puts
      puts "#{UI::COLORS[:dim]}Total: #{packages.length} packages#{UI::COLORS[:reset]}"
    end

    def depclean_packages
      portage_msg("Starting depclean")

      world = WorldManager.new
      world_atoms = Set.new(world.contents)

      installed = @database.list_packages
      to_remove = []

      installed.each do |name|
        pkg = @database.get_package(name)
        next unless pkg
        next unless pkg[:atom]

        atom = pkg[:atom].to_s.downcase
        category_name = pkg[:category] || "unknown"

        next if world_atoms.include?(atom)
        next if world_atoms.include?(category_name + "/" + name)
        next if world_atoms.include?(name)

        next if system_package?(pkg)

        dependents = find_dependents(pkg)
        if dependents.any?
          puts "#{UI::COLORS[:yellow]}Skipping #{pkg[:atom]}: required by #{dependents.join(', ')}#{UI::COLORS[:reset]}"
          next
        end

        to_remove << pkg
      end

      if to_remove.empty?
        puts
        portage_msg("No packages to remove")
        return
      end

      puts
      puts "#{UI::COLORS[:bold]}Packages to be removed:#{UI::COLORS[:reset]}"
      puts

      to_remove.each do |pkg|
        puts "  #{UI::COLORS[:red]}#{pkg[:atom]}#{UI::COLORS[:reset]}"
      end

      puts
      puts "#{UI::COLORS[:dim]}Total: #{to_remove.length} packages#{UI::COLORS[:reset]}"

      if @options[:pretend]
        return
      end

      if @options[:ask] && !confirm?("Remove these packages?")
        exit 0
      end

      removed = 0
      to_remove.each do |pkg|
        begin
          package = Package.new(pkg[:name])
          package.version = pkg[:version]
          package.category = pkg[:category]
          Installer.new(package, @database, options: @options).uninstall
          puts "#{UI::COLORS[:green]}Removed #{pkg[:atom]}#{UI::COLORS[:reset]}"
          removed += 1
        rescue => e
          puts "#{UI::COLORS[:red]}Failed to remove #{pkg[:atom]}: #{e.message}#{UI::COLORS[:reset]}"
        end
      end

      puts
      portage_msg("Depclean complete: #{removed} packages removed")
    end

    def find_dependents(package)
      dependents = []
      installed = @database.list_packages

      installed.each do |name|
        next if name == package[:name]

        pkg = @database.get_package(name)
        next unless pkg
        next unless pkg[:metadata]

        all_deps = Array(pkg[:metadata][:dependencies]) +
                   Array(pkg[:metadata][:build_dependencies])

        if all_deps.include?(package[:name])
          dependents << pkg[:atom]
        end
      end

      dependents
    end

    def system_package?(package)
      system_cats = %w[sys-libs sys-devel sys-kernel sys-apps dev-lang]
      system_cats.any? { |cat| package[:atom].to_s.start_with?(cat) }
    end

    def preserved_rebuild
      portage_msg("Scanning for preserved libraries...")

      preserved = find_preserved_libraries

      if preserved.empty?
        puts
        portage_msg("No preserved libraries found")
        return
      end

      puts
      puts "#{UI::COLORS[:yellow]}Preserved libraries detected:#{UI::COLORS[:reset]}"
      preserved.each do |lib, packages|
        puts "  #{UI::COLORS[:red]}#{lib}#{UI::COLORS[:reset]} - needed by #{packages.join(', ')}"
      end

      if @options[:pretend]
        return
      end

      puts
      if confirm?("Rebuild packages that need these libraries?")
        packages_to_rebuild = preserved.values.flatten.uniq
        packages_to_rebuild.each do |pkg_name|
          puts "Emerging #{pkg_name}..."
          system("quarks install #{pkg_name}")
        end
      end
    end

    def find_preserved_libraries
      preserved = {}

      lib_patterns = [
        File.join(Database::QUARKS_ROOT, "lib", "*.so.*"),
        File.join(Database::QUARKS_ROOT, "usr", "lib", "*.so.*")
      ]

      actual_libs = Set.new
      lib_patterns.each do |pattern|
        Dir.glob(pattern).each do |lib|
          actual_libs << File.basename(lib)
        end
      end

      @database.list_packages.each do |name|
        pkg = @database.get_package(name)
        next unless pkg

        pkg_files = Array(pkg[:files])
        pkg_libs = pkg_files.select { |f| f.include?(".so.") }

        pkg_libs.each do |lib_file|
          lib_name = File.basename(lib_file)
          next unless actual_libs.include?(lib_name)

          preserved[lib_name] ||= []
          preserved[lib_name] << pkg[:atom] unless preserved[lib_name].include?(pkg[:atom])
        end
      end

      preserved
    end

    def check_world
      portage_msg("Checking world file against repositories...")

      world = WorldManager.new
      issues = []

      world.contents.each do |atom|
        pkg = @repository.find_package(atom)
        unless pkg
          issues << { type: :missing, atom: atom }
          next
        end

        db_pkg = @database.get_package(pkg.name)
        if db_pkg
          if version_needs_update?(db_pkg[:version], pkg.version)
            issues << { type: :update, atom: atom, current: db_pkg[:version], available: pkg.version }
          end
        else
          issues << { type: :not_installed, atom: atom }
        end
      end

      if issues.empty?
        puts
        portage_msg("World file is in good state")
        return
      end

      puts
      puts "#{UI::COLORS[:bold]}World file issues:#{UI::COLORS[:reset]}"
      puts

      updates = issues.select { |i| i[:type] == :update }
      if updates.any?
        puts "#{UI::COLORS[:green]}Updates available:#{UI::COLORS[:reset]}"
        updates.each do |i|
          puts "  #{UI::COLORS[:cyan]}#{i[:atom]}#{UI::COLORS[:reset]} #{i[:current]} -> #{i[:available]}"
        end
        puts
      end

      missing = issues.select { |i| i[:type] == :missing }
      if missing.any?
        puts "#{UI::COLORS[:yellow]}Packages no longer in repositories:#{UI::COLORS[:reset]}"
        missing.each do |i|
          puts "  #{UI::COLORS[:dim]}#{i[:atom]}#{UI::COLORS[:reset]}"
        end
        puts
      end

      not_installed = issues.select { |i| i[:type] == :not_installed }
      if not_installed.any?
        puts "#{UI::COLORS[:yellow]}Packages in world but not installed:#{UI::COLORS[:reset]}"
        not_installed.each do |i|
          puts "  #{i[:atom]}"
        end
        puts
      end
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

    def run_query(args)
      if args.empty?
        show_query_help
        return
      end

      cmd = args.shift
      output, error = QueryCommands.run(cmd, args, @repository, @database)

      if error
        UI.error error
        exit 1
      else
        puts output
      end
    end

    def show_query_help
      puts
      puts "#{UI::COLORS[:brand]}Package Query Commands#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:dim]}Query package information and dependencies#{UI::COLORS[:reset]}"
      puts
      puts "Usage: #{UI::COLORS[:cyan]}quarks query <command> [args]#{UI::COLORS[:reset]}"
      puts
      puts "Available queries:"
      puts "  #{UI::COLORS[:brand]}deps#{UI::COLORS[:reset]}              Show package dependencies"
      puts "  #{UI::COLORS[:brand]}rdeps#{UI::COLORS[:reset]}             Show packages depending on this"
      puts "  #{UI::COLORS[:brand]}tree#{UI::COLORS[:reset]}               Draw dependency tree"
      puts "  #{UI::COLORS[:brand]}graph#{UI::COLORS[:reset]}              Generate graphviz output"
      puts "  #{UI::COLORS[:brand]}size#{UI::COLORS[:reset]}               Show package size"
      puts "  #{UI::COLORS[:brand]}audit#{UI::COLORS[:reset]}              Audit installed packages"
      puts "  #{UI::COLORS[:brand]}info#{UI::COLORS[:reset]}               Show package info"
      puts "  #{UI::COLORS[:brand]}whatprovides, wp#{UI::COLORS[:reset]}  Find package providing file"
      puts "  #{UI::COLORS[:brand]}manifest#{UI::COLORS[:reset]}            Show package manifest"
      puts "  #{UI::COLORS[:brand]}verify#{UI::COLORS[:reset]}             Verify package files"
      puts "  #{UI::COLORS[:brand]}stats#{UI::COLORS[:reset]}              Show statistics"
      puts "  #{UI::COLORS[:brand]}list#{UI::COLORS[:reset]}               List installed packages"
      puts
    end

    def hold_package(args)
      pm = PolicyManager.new

      if args.empty?
        puts
        puts "#{UI::COLORS[:brand]}Held packages:#{UI::COLORS[:reset]}"
        held = pm.list_held
        if held.empty?
          puts "  #{UI::COLORS[:dim]}None#{UI::COLORS[:reset]}"
        else
          held.each { |p| puts "  #{p.package}" }
        end
        return
      end

      pkg_name = args[0]

      if @database.installed?(pkg_name)
        pm.hold(pkg_name)
        puts "#{UI::COLORS[:brand]}Package #{pkg_name} held from updates#{UI::COLORS[:reset]}"
      else
        UI.error "Package not installed: #{pkg_name}"
        exit 1
      end
    end

    def release_package(args)
      if args.empty?
        UI.error "Usage: quarks release <package>"
        exit 1
      end

      pkg_name = args[0]
      pm = PolicyManager.new
      pm.release(pkg_name)
      puts "#{UI::COLORS[:brand]}Package #{pkg_name} released#{UI::COLORS[:reset]}"
    end

    def flag_package(args)
      if args.empty?
        pm = PolicyManager.new
        puts
        puts "#{UI::COLORS[:brand]}Flagged packages:#{UI::COLORS[:reset]}"
        flagged = pm.list_flagged
        if flagged.empty?
          puts "  #{UI::COLORS[:dim]}None#{UI::COLORS[:reset]}"
        else
          flagged.each { |p| puts "  #{p.package}: #{p.reason || 'no reason'}" }
        end
        return
      end

      pkg_name = args[0]
      reason = args[1]

      pm = PolicyManager.new
      pm.flag(pkg_name, reason: reason)
      puts "#{UI::COLORS[:brand]}Package #{pkg_name} flagged#{reason ? " (#{reason})" : ''}#{UI::COLORS[:reset]}"
    end

    def set_build(args)
      if args.empty?
        current = BuildConfig.current
        puts
        puts "#{UI::COLORS[:brand]}Build Configuration#{UI::COLORS[:reset]}"
        puts
        puts "  Current: #{UI::COLORS[:brand]}#{current}#{UI::COLORS[:reset]}"
        puts
        puts "  Available profiles:"
        puts "    #{UI::COLORS[:brand]}minimal#{UI::COLORS[:reset]}   - Single job, no verification"
        puts "    #{UI::COLORS[:brand]}default#{UI::COLORS[:reset]}   - Balanced (default)"
        puts "    #{UI::COLORS[:brand]}fast#{UI::COLORS[:reset]}      - Parallel builds, run tests"
        puts "    #{UI::COLORS[:brand]}extreme#{UI::COLORS[:reset]}    - Maximum parallelism"
        puts
        return
      end

      profile = args[0].to_sym
      BuildConfig.set(profile)
      puts "#{UI::COLORS[:brand]}Build config set to: #{profile}#{UI::COLORS[:reset]}"
      puts "  Jobs: #{BuildConfig.build_jobs}"
    end

    def manage_profiles(args)
      if args.empty? || args[0] == "list"
        profiles = ProfileManager.new.list
        puts
        puts "#{UI::COLORS[:brand]}Configuration Profiles#{UI::COLORS[:reset]}"
        puts
        active = ProfileManager.new.active
        profiles.each do |name, profile|
          marker = active && active["name"] == name ? " #{UI::COLORS[:green]}*#{UI::COLORS[:reset]}" : ""
          puts "  #{UI::COLORS[:brand]}#{name}#{UI::COLORS[:reset]}#{marker}"
        end
        puts
        return
      end

      subcmd = args[0]

      case subcmd
      when "create"
        name = args[1] || "myprofile"
        ProfileManager.new.create(name)
        puts "#{UI::COLORS[:brand]}Profile created: #{name}#{UI::COLORS[:reset]}"

      when "activate"
        name = args[1]
        if ProfileManager.new.activate(name)
          puts "#{UI::COLORS[:brand]}Profile activated: #{name}#{UI::COLORS[:reset]}"
        else
          UI.error "Profile not found: #{name}"
          exit 1
        end

      when "delete"
        name = args[1]
        if ProfileManager.new.delete(name)
          puts "#{UI::COLORS[:brand]}Profile deleted: #{name}#{UI::COLORS[:reset]}"
        else
          UI.error "Profile not found: #{name}"
          exit 1
        end

      else
        puts "Usage:"
        puts "  #{UI::COLORS[:cyan]}quarks profile#{UI::COLORS[:reset]}                   List profiles"
        puts "  #{UI::COLORS[:cyan]}quarks profile create <name>#{UI::COLORS[:reset]}      Create profile"
        puts "  #{UI::COLORS[:cyan]}quarks profile activate <name>#{UI::COLORS[:reset]}   Activate profile"
        puts "  #{UI::COLORS[:cyan]}quarks profile delete <name>#{UI::COLORS[:reset]}      Delete profile"
      end
    end

    def manage_hooks(args)
      if args.empty? || args[0] == "list"
        hooks = HookManager.list_hooks
        puts
        puts "#{UI::COLORS[:brand]}Hook Scripts#{UI::COLORS[:reset]}"
        puts
        if hooks.empty?
          puts "  #{UI::COLORS[:dim]}No hooks defined#{UI::COLORS[:reset]}"
        else
          hooks.each do |hook|
            puts "  #{UI::COLORS[:brand]}#{hook[:name]}#{UI::COLORS[:reset]} (#{hook[:size]} bytes)"
          end
        end
        puts
        return
      end

      subcmd = args[0]

      case subcmd
      when "create"
        name = args[1]
        unless name
          UI.error "Usage: quarks hook create <name>"
          exit 1
        end

        puts "Enter hook content (Ctrl+D to finish):"
        content = $stdin.read
        HookManager.create_hook(name, content)
        puts "#{UI::COLORS[:brand]}Hook created: #{name}#{UI::COLORS[:reset]}"

      when "run"
        name = args[1]
        unless name
          UI.error "Usage: quarks hook run <name>"
          exit 1
        end

        result = HookManager.run_hook(name, args: args[2..-1])
        if result
          puts result
        else
          UI.error "Hook not found: #{name}"
          exit 1
        end

      when "delete"
        name = args[1]
        if HookManager.delete_hook(name)
          puts "#{UI::COLORS[:brand]}Hook deleted: #{name}#{UI::COLORS[:reset]}"
        else
          UI.error "Hook not found: #{name}"
          exit 1
        end

      else
        UI.error "Unknown hook command: #{subcmd}"
        exit 1
      end
    end

    def show_status
      pm = PolicyManager.new
      world = WorldManager.new

      puts
      puts "#{UI::COLORS[:brand]}╔#{'═' * 50}╗#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}#{UI::COLORS[:bold]}       Quarks Status#{UI::COLORS[:reset]}#{' ' * 28}#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}╠#{'═' * 50}╣#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}  Packages: #{@database.list_packages.length.to_s.ljust(43)}#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}  Available: #{@repository.list_atoms.length.to_s.ljust(41)}#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}  World: #{world.contents.length.to_s.ljust(44)}#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}╠#{'═' * 50}╣#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}  Build: #{BuildConfig.current.to_s.ljust(46)}#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}  Held: #{pm.list_held.length.to_s.ljust(47)}#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}  Flagged: #{pm.list_flagged.length.to_s.ljust(45)}#{UI::COLORS[:brand]}║#{UI::COLORS[:reset]}"
      puts "#{UI::COLORS[:brand]}╚#{'═' * 50}╝#{UI::COLORS[:reset]}"
      puts
    end

    def set_sync(args)
      if args.empty?
        puts
        puts "#{UI::COLORS[:brand]}Sync Mode#{UI::COLORS[:reset]}"
        puts
        puts "  Available modes:"
        puts "    #{UI::COLORS[:brand]}full#{UI::COLORS[:reset]}        - Complete sync"
        puts "    #{UI::COLORS[:brand]}incremental#{UI::COLORS[:reset]}  - Smart sync (default)"
        puts "    #{UI::COLORS[:brand]}shallow#{UI::COLORS[:reset]}      - Changed packages only"
        puts "    #{UI::COLORS[:brand]}mirror#{UI::COLORS[:reset]}       - Raw download"
        puts
        return
      end

      mode = args[0].to_sym
      sync = SyncMode.new(mode: mode)
      puts "#{UI::COLORS[:brand]}Sync mode set to: #{sync}#{UI::COLORS[:reset]}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  Quarks::CLI.new.run(ARGV)
end
