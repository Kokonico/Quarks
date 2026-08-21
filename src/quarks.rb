#!/usr/bin/env ruby
# frozen_string_literal: true

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
begin
  Quarks::Config.apply_env!
rescue Quarks::Config::Error => e
  if __FILE__ == $PROGRAM_NAME
    warn "quarks: #{e.message}"
    exit 2
  end
  raise
end
require "quarks/env"
require "quarks/signal_handler"
require "quarks/version"

module Quarks
  AUTHOR  = "Quarks Developers"

  class CLI
    HEAVY_COMMANDS = %w[
      install i emerge remove uninstall r rm unmerge search s find list l ls qlist
      info show metadata files which owner update sync upgrade up clean eclean compact-db
      debug world depclean preserved-rebuild check-world query q beam hold freeze release thaw
      flag status
    ].freeze
    REPOSITORY_COMMANDS = %w[
      install i emerge search s find info show metadata update sync upgrade up
      debug world check-world query q beam status
    ].freeze
    USE_COMMANDS = %w[install i emerge upgrade up].freeze
    INSTALL_STATE_COMMANDS = %w[install i emerge].freeze

    def initialize
      setup_signal_handling!
      ensure_admin_paths!

      @database = nil
      @repository = nil
      @use_config = nil
      @emerge_queue = nil
      @logger = nil
      @build_state_manager = nil

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
      @resume_queue_state = @emerge_queue.load
      if saved_state
        puts "#{UI::COLORS[:green]}>>> Resuming from saved state...#{UI::COLORS[:reset]}"
        if saved_state["package"]
          puts "  Previous package: #{saved_state['package']}"
        end
      end

      if @resume_queue_state && @resume_queue_state["packages"]
        puts "#{UI::COLORS[:green]}>>> Resuming emerge queue...#{UI::COLORS[:reset]}"
        progress = @resume_queue_state["progress"] || {}
        puts "  Packages: #{progress['done'].to_i}/#{progress['total'].to_i}"
      end

      if saved_state || @resume_queue_state
        true
      else
        puts "#{UI::COLORS[:yellow]}>>> No saved state found#{UI::COLORS[:reset]}"
        false
      end
    end

    def run(args)
      parse_global_flags!(args)

      if args.empty?
        show_help
        return
      end

      command = args.shift.to_s
      if %w[search s find].include?(command) && args.empty?
        UI.error "Usage: quarks search <term>..."
        exit 1
      end
      load_command_requirements!(command)
      initialize_services!(command) if HEAVY_COMMANDS.include?(command)

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
      when "upgrade", "up" then upgrade_packages
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
      when "freeze" then hold_package(args)
      when "release" then release_package(args)
      when "thaw" then release_package(args)
      when "flag" then flag_package(args)
      when "build" then set_build(args)
      when "flux" then set_build(args)
      when "profile" then manage_profiles(args)
      when "hook" then manage_hooks(args)
      when "spark" then manage_hooks(args)
      when "status" then show_status
      when "sync-mode", "wavelength" then set_sync(args)
      when "beam" then run_query(args)
      else
        UI.error "Unknown command: #{command}"
        puts "Run #{UI::COLORS[:cyan]}quarks help#{UI::COLORS[:reset]} for usage information."
        exit 1
      end
    rescue Interrupt
      puts
      quarks_msg("Interrupted by user", :warn)
      exit 130
    rescue => e
      quarks_msg(e.message, :error)

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

    def load_command_requirements!(command)
      if %w[install i emerge].include?(command)
        load_install_requirements!
      elsif %w[upgrade up].include?(command)
        load_upgrade_requirements!
      elsif %w[remove uninstall r rm unmerge depclean].include?(command)
        require "set"
        require "quarks/package"
        require "quarks/database"
        require "quarks/installer"
        require "quarks/path_integration"
        require "quarks/system_integration"
      elsif %w[search s find info show metadata update sync debug world check-world status].include?(command)
        require "quarks/package"
        require "quarks/database"
        require "quarks/repository"
        require "quarks/path_integration" if command == "debug"
        require "quarks/core" if %w[update sync status].include?(command)
      elsif %w[query q beam].include?(command)
        require "quarks/package"
        require "quarks/database"
        require "quarks/repository"
        require "quarks/query"
      elsif HEAVY_COMMANDS.include?(command)
        require "set" if command == "preserved-rebuild"
        require "quarks/database"
        require "quarks/core" if %w[hold freeze release thaw flag].include?(command)
      elsif command == "use"
        require "quarks/use_slots"
      elsif %w[add-repo remove-repo list-repos].include?(command)
        require "quarks/web_repo"
      elsif %w[enable-service disable-service].include?(command)
        require "quarks/systemd_manager"
      elsif %w[paths env setup-path].include?(command)
        require "quarks/database"
        require "quarks/path_integration"
      elsif %w[build flux profile hook spark sync-mode wavelength].include?(command)
        require "quarks/use_slots"
        require "quarks/core"
      end
    end

    def load_install_requirements!
      require "find"
      require "fileutils"
      require "quarks/package"
      require "quarks/database"
      require "quarks/repository"
      require "quarks/resolver"
      require "quarks/builder"
      require "quarks/installer"
      require "quarks/path_integration"
      require "quarks/system_integration"
      require "quarks/use_slots"
      require "quarks/smart_resolver"
      require "quarks/sandbox_build"
      require "quarks/core"
    end

    def load_upgrade_requirements!
      require "find"
      require "fileutils"
      require "quarks/package"
      require "quarks/database"
      require "quarks/repository"
      require "quarks/resolver"
      require "quarks/builder"
      require "quarks/installer"
      require "quarks/path_integration"
      require "quarks/system_integration"
      require "quarks/use_slots"
      require "quarks/smart_resolver"
      require "quarks/sandbox_build"
      require "quarks/core"
    end

    def initialize_services!(command)
      @database ||= Database.new
      @repository ||= Repository.new if REPOSITORY_COMMANDS.include?(command)
      @use_config ||= USEConfig.new if USE_COMMANDS.include?(command)
      if INSTALL_STATE_COMMANDS.include?(command)
        @emerge_queue ||= EmergeQueue.new
        @logger ||= EmergeLogger.new
        @build_state_manager ||= BuildStateManager.new
      end
      if USE_COMMANDS.include?(command) && ENV["QUARKS_JOBS"].to_s.empty? && defined?(BuildConfig)
        @options[:jobs] = BuildConfig.build_jobs
      end
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
          raise "Build jobs must be between 1 and 1024" unless @options[:jobs].between?(1, 1024)
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
      puts "#{UI::COLORS[:dim]}Secure source package management with local and signed remote repositories#{UI::COLORS[:reset]}"
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
      puts "  #{UI::COLORS[:green]}--config PATH#{UI::COLORS[:reset]}          Load an explicit configuration file"
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
      puts "  #{UI::COLORS[:brand]}sync-mode#{UI::COLORS[:reset]}            Set persistent repository sync mode"
      puts "  #{UI::COLORS[:brand]}status#{UI::COLORS[:reset]}               System status overview"
      puts Quarks::Env.help_section
    end

    def install_packages(package_names)
      if package_names.empty?
        quarks_msg("No packages specified", :error)
        puts "Usage: #{UI::COLORS[:cyan]}quarks install <package>...#{UI::COLORS[:reset]}"
        exit 1
      end

      check_resume! if @options[:resume]

      resolver = SmartResolver.new(@repository, @database, use_config: @use_config)
      blocker_mgr = BlockerManager.new(@repository, @database)

      all_packages = []

      if @options[:nodeps]
        package_names.each do |name|
          pkg = @repository.find_package(name)
          if pkg
            all_packages << pkg unless @database.installed?(pkg.name)
          else
            quarks_msg("Package not found: #{name}", :error)
            suggest_packages(name)
            exit 1
          end
        end
      else
        begin
          all_packages = resolver.resolve_all(package_names)
        rescue SmartResolver::CircularDependencyError => e
          quarks_msg("Circular dependency: #{e.cycle.join(' -> ')}", :error)
          exit 1
        rescue SmartResolver::MissingDependencyError => e
          quarks_msg("Missing dependency: #{e.dependency}", :error)
          exit 1
        rescue SmartResolver::BlockedPackageError => e
          quarks_msg("Blocked package: #{e.message}", :error)
          exit 1
        rescue => e
          quarks_msg("Cannot resolve transaction: #{e.message}", :error)
          exit 1
        end
      end

      all_packages.uniq! { |pkg| pkg.atom }
      if @resume_queue_state
        completed_names = Array(@resume_queue_state["completed"]).filter_map do |entry|
          entry.is_a?(Hash) ? (entry["name"] || entry.dig("package", "name")) : nil
        end.to_set
        all_packages.reject! { |package| completed_names.include?(package.name) }
      end
      requested_atoms = package_names.filter_map { |name| @repository.find_package(name)&.atom }.to_set

      policy_manager = PolicyManager.new
      denied = all_packages.select { |pkg| policy_manager.is_masked?(pkg.name) || policy_manager.is_held?(pkg.name) }
      unless denied.empty?
        denied.each { |pkg| quarks_msg("Package is held or masked: #{pkg.atom}", :error) }
        exit 1
      end

      all_packages.each do |pkg|
        blocker_mgr.load_blockers!(pkg)
        blockers = blocker_mgr.check_blockers(pkg)
        unless blockers.empty?
          blockers.each do |block|
            quarks_msg("Blocker: #{block[:message]}", :error)
          end
          exit 1
        end
      end

      if all_packages.empty?
        puts
        quarks_msg("No packages to install")
        if @options[:resume]
          @emerge_queue.clear
          @build_state_manager.clear_state
        end
        return
      end

      puts
      puts "#{UI::COLORS[:bold]}These are the packages that would be merged, in order:#{UI::COLORS[:reset]}"
      puts

      source_sizes = SourceSize.new
      size_by_atom = all_packages.to_h { |package| [package.atom, source_sizes.measure(package)] }
      dependency_reasons = Hash.new { |hash, atom| hash[atom] = [] }
      unless @options[:nodeps]
        all_packages.each do |parent|
          resolver.dependency_details_for(parent).each do |dependency|
            dependency_reasons[dependency[:atom]] << { parent: parent.atom, type: dependency[:type] }
          end
        end
      end
      all_packages.each do |pkg|
        marker = @database.installed?(pkg.name) ? "R" : "N"
        size = format_source_size(size_by_atom.fetch(pkg.atom))
        slot_info = pkg.slot ? ":#{pkg.slot}" : ""
        color = marker == "N" ? UI::COLORS[:bright_green] : UI::COLORS[:bright_blue]
        puts "#{color}[#{marker}#{slot_info}]#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}#{pkg.atom}-#{pkg.version}#{UI::COLORS[:reset]} #{UI::COLORS[:dim]}[#{size}]#{UI::COLORS[:reset]}"

        unless requested_atoms.include?(pkg.atom)
          reasons = dependency_reasons[pkg.atom].map { |reason| "#{reason[:parent]} (#{reason[:type]})" }.uniq
          puts "      #{UI::COLORS[:dim]}required by: #{reasons.join(', ')}#{UI::COLORS[:reset]}" if reasons.any?
        end

        if pkg.blocks.any?
          puts "      #{UI::COLORS[:yellow]}blocks: #{pkg.blocks.join(', ')}#{UI::COLORS[:reset]}"
        end
      end

      total_size = size_by_atom.values.reduce(
        SourceSize::Result.new(total_bytes: 0, download_bytes: 0, cached_bytes: 0, unknown_sources: 0)
      ) do |total, size|
        total.total_bytes += size.total_bytes
        total.download_bytes += size.download_bytes
        total.cached_bytes += size.cached_bytes
        total.unknown_sources += size.unknown_sources
        total
      end
      puts
      total_label = total_size.unknown_sources.positive? ? "at least #{UI.format_bytes(total_size.download_bytes)}" : UI.format_bytes(total_size.download_bytes)
      puts "#{UI::COLORS[:bold]}Total:#{UI::COLORS[:reset]} #{all_packages.length} package(s), Downloads: #{total_label}"
      puts "#{UI::COLORS[:dim]}Cached sources: #{UI.format_bytes(total_size.cached_bytes)}#{", Unknown source sizes: #{total_size.unknown_sources}" if total_size.unknown_sources.positive?}#{UI::COLORS[:reset]}"

      if @options[:pretend]
        puts
        quarks_msg("Pretend run (--pretend). Nothing was installed.", :warn)

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
        quarks_msg("Aborting", :warn)
        exit 0
      end

      if @options[:fetchonly]
        puts
        quarks_msg("Fetching sources only (--fetchonly)")
        all_packages.each do |pkg|
          Builder.new(pkg, 1, 1, @options.merge(use_flags: @use_config.flags_for_package(pkg))).fetch_only
        end
        return
      end


      all_packages.each do |package|
        dependencies = @options[:nodeps] ? [] : resolver.dependency_atoms_for(package)
        @emerge_queue.add(package, deps: dependencies)
      end
      @emerge_queue.save

      successful = 0
      failed = []
      skipped = []
      unavailable_atoms = Set.new
      started_at = Time.now

      all_packages.each_with_index do |package, index|
        SignalHandler.instance.check_and_raise!

        unavailable_dependencies = resolver.dependency_atoms_for(package).select { |atom| unavailable_atoms.include?(atom) }
        if unavailable_dependencies.any?
          reason = "required package failed: #{unavailable_dependencies.join(', ')}"
          skipped << { atom: package.atom, reason: reason }
          unavailable_atoms << package.atom
          @emerge_queue.mark_failed(package.name, error: SmartResolver::ResolutionError.new(reason))
          @emerge_queue.save
          puts
          puts "#{UI::COLORS[:yellow]}>>> Skipping #{package.atom}-#{package.version} (#{reason})#{UI::COLORS[:reset]}"
          next
        end

        current = index + 1
        total = all_packages.length

        puts
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Emerging (#{current}/#{total}) #{package.atom}-#{package.version}#{UI::COLORS[:reset]}"

        @build_state_manager.save_state({
          "package" => package.to_h,
          "phase" => "building",
          "started_at" => Time.now.iso8601
        })

        pkg_started_at = Time.now
        builder = nil
        begin
          @emerge_queue.mark_start(package.name)
          @emerge_queue.save
          build_options = @options.merge(resume: false, use_flags: @use_config.flags_for_package(package))
          builder = Builder.new(package, current, total, build_options)
          dest_dir = builder.build

          install_options = @options.merge(world: requested_atoms.include?(package.atom))
          installer = Installer.new(package, @database, options: install_options)
          installer.install(dest_dir)

          PathIntegration.sync!(@database)

          @logger.log_success(package, Time.now - pkg_started_at)
          successful += 1
          @emerge_queue.mark_complete(package.name)
          @emerge_queue.save
          @build_state_manager.clear_state

          puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Successfully merged #{package.atom}-#{package.version} #{UI::COLORS[:dim]}(#{format_time(Time.now - pkg_started_at)})#{UI::COLORS[:reset]}"

        rescue Quarks::InterruptedError
          puts "\n#{UI::COLORS[:yellow]}>>> Interrupted! State saved.#{UI::COLORS[:reset]}"
          save_emerge_state!
          exit 130

        rescue => e
          @logger.log_failure(package, e)
          failed << { atom: package.atom, error: e.message }
          @emerge_queue.mark_failed(package.name, error: e)
          @emerge_queue.save
          puts "#{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} #{UI::COLORS[:red]}Failed to emerge #{package.atom}: #{e.message}#{UI::COLORS[:reset]}"

          if @options[:keep_going]
            unavailable_atoms << package.atom
            next
          end

          break unless confirm?("Continue with remaining packages?", default_yes: false)
        ensure
          builder&.cleanup!
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
        skipped.each { |entry| puts "  #{entry[:atom]} (#{entry[:reason]})" }
      end

      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{UI::COLORS[:bold]}Total time:#{UI::COLORS[:reset]} #{format_time(Time.now - started_at)}"

      if failed.empty?
        @emerge_queue.clear
        @build_state_manager.clear_state
      end

      exit 1 if failed.any? || skipped.any?
    end

    def remove_packages(package_names)
      if package_names.empty?
        quarks_msg("No packages specified", :error)
        puts "Usage: #{UI::COLORS[:cyan]}quarks remove <package>...#{UI::COLORS[:reset]}"
        exit 1
      end

      resolved_names = package_names.map { |name| @database.normalize_name(name) }
      to_remove = resolved_names.select do |name|
        if @database.installed?(name)
          true
        else
          quarks_msg("Package '#{name}' is not installed", :warn)
          false
        end
      end

      if to_remove.empty?
        puts "Nothing to do."
        return
      end

      unless @options[:force]
        blocked = to_remove.each_with_object({}) do |name, result|
          info = @database.get_package(name)
          next unless info
          dependents = find_dependents(info).reject do |atom|
            to_remove.include?(@database.normalize_name(atom))
          end
          result[info[:atom] || name] = dependents unless dependents.empty?
        end
        unless blocked.empty?
          blocked.each do |atom, dependents|
            quarks_msg("Cannot remove #{atom}; required by #{dependents.join(', ')}", :error)
          end
          puts "Use --force only if you intend to break these dependents."
          exit 1
        end
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

      if @options[:pretend]
        puts
        quarks_msg("Pretend run (--pretend). Nothing was removed.", :warn)
        return
      end

      if @options[:ask] && !confirm?("Would you like to unmerge these packages?")
        puts
        quarks_msg("Aborting", :warn)
        exit 0
      end

      puts
      removed = 0
      failures = []
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
          removed += 1
          puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Successfully unmerged #{info[:atom] || name}"
        rescue => e
          failures << { atom: info[:atom] || name, error: e.message }
          quarks_msg("Failed to unmerge #{info[:atom] || name}: #{e.message}", :error)
        end
      end

      puts
      puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} Unmerge complete: #{removed} package(s) removed"
      unless failures.empty?
        puts "#{UI::COLORS[:red]}!!!#{UI::COLORS[:reset]} #{failures.length} package(s) failed to unmerge"
        exit 1
      end
    end

    def search_packages(terms)
      atoms = @repository.list_atoms
      if atoms.empty?
        quarks_msg("No packages available", :warn)
        puts "Repository sources checked:"
        @repository.source_overview.each do |source|
          puts "  #{UI::COLORS[:dim]}#{source[:type]}: #{source[:location]}#{UI::COLORS[:reset]}"
        end
        return
      end

      packages = atoms.filter_map { |atom| @repository.find_package(atom) }
      results = if terms.empty?
        packages
      else
        query = terms.join(" ")
        pattern = Regexp.new(Regexp.escape(query).gsub("\\ ", ".*"), Regexp::IGNORECASE)

        packages.select do |pkg|
          [pkg.atom, pkg.description, pkg.category, pkg.name].compact.any? { |value| value.to_s.match?(pattern) }
        end
      end

      if results.empty?
        quarks_msg("No matches found", :warn)
        suggest_packages(terms.join(" "))
        return
      end

      puts
      results.sort_by(&:atom).each do |pkg|
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
        quarks_msg("No packages installed", :warn)
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
        quarks_msg("No package specified", :error)
        puts "Usage: #{UI::COLORS[:cyan]}quarks info <package>#{UI::COLORS[:reset]}"
        exit 1
      end

      pkg = @repository.find_package(name)
      unless pkg
        quarks_msg("Package '#{name}' not found", :error)
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
        quarks_msg("No package specified", :error)
        puts "Usage: quarks files <package>"
        exit 1
      end

      pkg = @database.get_package(name)
      unless pkg
        quarks_msg("Not installed: #{name}", :error)
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
        quarks_msg("No command specified", :error)
        puts "Usage: quarks which <cmd>"
        exit 1
      end

      who = @database.which_command(cmd.strip)
      if who
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{cmd} is provided by #{UI::COLORS[:bold]}#{who[:atom]}#{UI::COLORS[:reset]} (#{who[:path]})"
      else
        quarks_msg("No package provides '#{cmd}'", :warn)
      end
    end

    def owner_of_path(path)
      unless path && !path.strip.empty?
        quarks_msg("No path specified", :error)
        puts "Usage: quarks owner <path>"
        exit 1
      end

      who = @database.owner_of(path.strip)
      if who
        puts "#{UI::COLORS[:green]}>>>#{UI::COLORS[:reset]} #{path} is owned by #{UI::COLORS[:bold]}#{who[:atom]}#{UI::COLORS[:reset]}"
      else
        quarks_msg("No owner found for #{path}", :warn)
      end
    end

    def update_repository
      quarks_msg("Refreshing repository metadata")
      sync = SyncMode.new
      count = @repository.update(force: sync.full_sync?)
      quarks_msg("Repository ready: #{count} packages available")
    end

    def upgrade_packages
      if @options[:pretend]
        quarks_msg("Performing a dry run upgrade check")
      else
        quarks_msg("Starting system upgrade")
      end

      world_packages = @database.world_list
      if world_packages.empty?
        installed = @database.list_packages
        if installed.empty?
          quarks_msg("No packages installed", :warn)
          return
        end
        quarks_msg("World file empty, checking all installed packages for updates")
        @upgrade_targets = installed
      else
        @upgrade_targets = world_packages
      end

      updates_available = []
      up_to_date = []

      policy = PolicyManager.new
      @upgrade_targets.each do |atom|
        pkg = @repository.find_package(atom)
        unless pkg
          up_to_date << { atom: atom, reason: "Not in repositories" }
          next
        end

        db_pkg = @database.get_package(pkg.name)
        if db_pkg
          if policy.is_held?(pkg.name) || policy.is_masked?(pkg.name)
            up_to_date << { atom: atom, current_version: db_pkg[:version], reason: "held or masked" }
          elsif version_needs_update?(db_pkg[:version], pkg.version)
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
        quarks_msg("System is up to date!")
        if up_to_date.any? && !@options[:quiet]
          puts
          puts "#{UI::COLORS[:dim]}#{up_to_date.length} packages checked#{UI::COLORS[:reset]}"
        end
        return
      end

      resolver = SmartResolver.new(@repository, @database, use_config: @use_config)
      packages_to_build = []
      updates_available.each do |update|
        begin
          resolver.resolve(update[:package].name).each do |pkg|
            packages_to_build << pkg unless packages_to_build.any? { |candidate| candidate.name == pkg.name }
          end
        rescue => e
          quarks_msg("Cannot resolve upgrade for #{update[:atom]}: #{e.message}", :error)
          exit 1
        end
      end
      packages_to_build.uniq! { |pkg| pkg.name }
      if packages_to_build.empty?
        quarks_msg("Resolved upgrade plan is empty", :error)
        exit 1
      end

      denied = packages_to_build.select { |pkg| policy.is_masked?(pkg.name) || policy.is_held?(pkg.name) }
      unless denied.empty?
        denied.each { |pkg| quarks_msg("Upgrade dependency is held or masked: #{pkg.atom}", :error) }
        exit 1
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
      puts
      puts "#{UI::COLORS[:bold]}Resolved build plan (including dependencies):#{UI::COLORS[:reset]}"
      packages_to_build.each do |pkg|
        marker = @database.installed?(pkg.name) ? "U" : "N"
        color = marker == "U" ? UI::COLORS[:bright_blue] : UI::COLORS[:bright_green]
        puts "#{color}[#{marker}]#{UI::COLORS[:reset]} #{pkg.atom}-#{pkg.version}"
      end

      if @options[:pretend]
        puts
        quarks_msg("Pretend run (--pretend). Nothing was upgraded.", :warn)
        return
      end

      if @options[:ask] && !confirm?("Would you like to upgrade these packages?")
        puts
        quarks_msg("Aborting upgrade", :warn)
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

        builder = nil
        begin
          pkg_started_at = Time.now
          builder = Builder.new(package, current, total, @options.merge(use_flags: @use_config.flags_for_package(package)))
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
        ensure
          builder&.cleanup!
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
      return false if available.nil? || available.empty?

      Quarks::Versioning.newer?(available, current)
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
      quarks_msg("Cleaning cache")
      total = 0

      @database.cache_dirs.each do |dir|
        next unless Dir.exist?(dir)
        total += dir_size(dir)
        FileUtils.rm_rf(dir)
      end

      if total.positive?
        quarks_msg("Cleaned #{UI.format_bytes(total)}")
      else
        puts "Cache already clean"
      end
    end

    def run_doctor
      script = File.expand_path("../tools/quarks_doctor.rb", __dir__)
      exec(RbConfig.ruby, script)
    end

    def debug_info
      quarks_msg("Debug Information")
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
      puts PathIntegration.environment_lines
    end

    def setup_path
      PathIntegration.setup_path!
      quarks_msg("PATH integration installed!")
      puts "#{UI::COLORS[:dim]}(Restart your shell or source your rc file.)#{UI::COLORS[:reset]}"
    end

    def compact_db
      quarks_msg("Compacting database")
      @database.compact!
      stats = @database.stats
      quarks_msg("DB compact complete (pages=#{stats[:page_count]} free=#{stats[:freelist_count]})")
    end

    def add_repository(args)
      if args.length < 2
        puts "Usage: #{UI::COLORS[:cyan]}quarks add-repo <name> <url> [--priority N] --gpg-key-id FINGERPRINT [--gpg-key-url URL]#{UI::COLORS[:reset]}"
        puts
        puts "Options:"
        puts "  --priority N      Repository priority (lower = higher priority, default: 100)"
        puts "  --gpg-key-id ID  GPG key ID for signature verification"
        puts "  --gpg-key-url URL URL to download GPG key"
        puts "  --allow-unsigned   Explicitly trust an unsigned repository (unsafe)"
        exit 1
      end

      name = args[0]
      url = args[1]
      priority = 100
      gpg_key_id = nil
      gpg_key_url = nil
      allow_insecure = false

      args[2..].each_with_index do |arg, i|
        case arg
        when "--priority"
          priority = args[i + 3].to_i rescue 100
        when "--gpg-key-id"
          gpg_key_id = args[i + 3]
        when "--gpg-key-url"
          gpg_key_url = args[i + 3]
        when "--allow-unsigned"
          allow_insecure = true
        end
      end

      unless url.start_with?("http://", "https://")
        UI.error "Repository URL must start with http:// or https://"
        exit 1
      end

      if allow_insecure && ENV["QUARKS_ALLOW_UNSIGNED_REPOS"] != "1"
        UI.error "--allow-unsigned also requires QUARKS_ALLOW_UNSIGNED_REPOS=1 (or allow_unsigned_repositories=true in config)."
        exit 1
      end

      if !allow_insecure && gpg_key_id.to_s.empty?
        UI.error "A pinned GPG fingerprint is required. Use --allow-unsigned only for a repository you explicitly trust."
        exit 1
      end

      if !allow_insecure && gpg_key_url.to_s.empty?
        UI.error "A trusted key URL is required for first use (--gpg-key-url HTTPS_URL)."
        exit 1
      end

      Quarks::WebRepoManager.add_repo(
        name: name,
        url: url,
        priority: priority,
        gpg_key_id: gpg_key_id,
        gpg_key_url: gpg_key_url,
        allow_insecure: allow_insecure
      )

      puts
      quarks_msg("Repository '#{name}' added successfully")
      puts "  URL: #{url}"
      puts "  Priority: #{priority}"
      puts "  GPG Key: #{gpg_key_id || 'not configured'}"

      if @options[:ask]
        puts
        if confirm?("Sync repository now?")
          sync_result = Quarks::WebRepoManager.sync_repo(name, force: true)
          if sync_result
            quarks_msg("Repository synced successfully")
          else
            quarks_msg("Repository sync failed", :warn)
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
        quarks_msg("No web repositories configured")
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
        quarks_msg("Service '#{name}' enabled")
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
        quarks_msg("Service '#{name}' disabled")
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
      elsif %w[mask unmask force unforce].include?(args[0])
        update_use_policy(args[0], args[1..-1])
      elsif args[0] == "explain"
        explain_package_use(args[1])
      else
        puts "Usage:"
        puts "  #{UI::COLORS[:cyan]}quarks use#{UI::COLORS[:reset]}                 Show current USE flags"
        puts "  #{UI::COLORS[:cyan]}quarks use set <flags>...#{UI::COLORS[:reset]}  Set global USE flags"
        puts "  #{UI::COLORS[:cyan]}quarks use del <flags>...#{UI::COLORS[:reset]}  Remove global USE flags"
        puts "  #{UI::COLORS[:cyan]}quarks use package <pkg> <flags>#{UI::COLORS[:reset]} Set package-specific flags"
        puts "  #{UI::COLORS[:cyan]}quarks use mask|unmask <pkg|*> <flags>#{UI::COLORS[:reset]} Mask package flags"
        puts "  #{UI::COLORS[:cyan]}quarks use force|unforce <pkg|*> <flags>#{UI::COLORS[:reset]} Force package flags"
        puts "  #{UI::COLORS[:cyan]}quarks use explain <pkg>#{UI::COLORS[:reset]} Show effective package flags"
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
      quarks_msg("USE flags updated")
      show_use_flags
    end

    def remove_use_flags(flags)
      use_config = USEConfig.new
      flags.each { |f| use_config.remove_flag(f) }
      use_config.save!
      quarks_msg("USE flags updated")
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
      quarks_msg("Package USE flags set for #{package}: #{flags.join(' ')}")
    end

    def update_use_policy(action, args)
      if args.length < 2
        UI.error "Usage: quarks use #{action} <package|*> <flags...>"
        exit 1
      end

      package, *flags = args
      use_config = USEConfig.new
      method = {
        "mask" => :mask_package_flag,
        "unmask" => :unmask_package_flag,
        "force" => :force_package_flag,
        "unforce" => :unforce_package_flag
      }.fetch(action)
      flags.each { |flag| use_config.public_send(method, package, flag) }
      use_config.save!
      quarks_msg("USE #{action} policy updated for #{package}")
    end

    def explain_package_use(package)
      if package.to_s.empty?
        UI.error "Usage: quarks use explain <package>"
        exit 1
      end

      use_config = USEConfig.new
      puts "Effective: #{use_config.flags_for_package(package).join(' ')}"
      puts "Masked:   #{use_config.masked_flags(package).join(' ')}"
      puts "Forced:   #{use_config.forced_flags(package).join(' ')}"
    end

    def show_world
      packages = @database.world_list

      if packages.empty?
        puts
        quarks_msg("World file is empty")
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
      quarks_msg("Starting depclean")

      world_atoms = Set.new(@database.world_list)

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
        quarks_msg("No packages to remove")
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
      quarks_msg("Depclean complete: #{removed} packages removed")
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
      quarks_msg("Scanning for preserved libraries...")

      preserved = find_preserved_libraries

      if preserved.empty?
        puts
        quarks_msg("No preserved libraries found")
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
          system(File.expand_path($PROGRAM_NAME), "install", pkg_name.to_s)
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
      quarks_msg("Checking world file against repositories...")

      issues = []

      @database.world_list.each do |atom|
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
        quarks_msg("World file is in good state")
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

    def quarks_msg(message, type = :info)
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
      return false unless name.to_s.match?(/\A[A-Za-z0-9][A-Za-z0-9+_.-]*\z/)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        File.executable?(File.join(directory, name.to_s))
      end
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

    def format_source_size(size)
      if size.download_bytes.positive?
        label = "download #{UI.format_bytes(size.download_bytes)}"
      elsif size.cached_bytes.positive?
        label = "cached #{UI.format_bytes(size.cached_bytes)}"
      elsif size.unknown_sources.zero?
        label = "no download"
      else
        label = "download size unknown"
      end
      label += ", #{size.unknown_sources} unknown" if size.unknown_sources.positive? && size.download_bytes.positive?
      label
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
        puts "    #{UI::COLORS[:brand]}minimal#{UI::COLORS[:reset]}   - Single build job"
        puts "    #{UI::COLORS[:brand]}default#{UI::COLORS[:reset]}   - Balanced (default)"
        puts "    #{UI::COLORS[:brand]}fast#{UI::COLORS[:reset]}      - Up to 2x detected CPU jobs"
        puts "    #{UI::COLORS[:brand]}extreme#{UI::COLORS[:reset]}   - Up to 4x detected CPU jobs"
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
      width = 50
      border = UI::COLORS[:brand]
      reset = UI::COLORS[:reset]
      row = lambda do |label, value|
        content = "  #{label}: #{value}"
        puts "#{border}║#{reset}#{content.ljust(width)}#{border}║#{reset}"
      end

      puts
      puts "#{border}╔#{'═' * width}╗#{reset}"
      puts "#{border}║#{reset}#{UI::COLORS[:bold]}#{'Quarks Status'.center(width)}#{reset}#{border}║#{reset}"
      puts "#{border}╠#{'═' * width}╣#{reset}"
      row.call("Packages", @database.list_packages.length)
      row.call("Available", @repository.list_atoms.length)
      row.call("World", @database.world_list.length)
      puts "#{border}╠#{'═' * width}╣#{reset}"
      row.call("Build", BuildConfig.current)
      row.call("Sync", SyncMode.current)
      row.call("Held", pm.list_held.length)
      row.call("Flagged", pm.list_flagged.length)
      puts "#{border}╚#{'═' * width}╝#{reset}"
      puts
    end

    def set_sync(args)
      if args.empty?
        puts
        puts "#{UI::COLORS[:brand]}Sync Mode#{UI::COLORS[:reset]}"
        puts
        puts "  Available modes:"
        puts "    #{UI::COLORS[:brand]}full#{UI::COLORS[:reset]}        - Force a fresh, verified download"
        puts "    #{UI::COLORS[:brand]}incremental#{UI::COLORS[:reset]}  - Verified cache + conditional requests (default)"
        puts
        puts "  Current: #{SyncMode.current}"
        puts
        return
      end

      mode = SyncMode.set(args[0])
      puts "#{UI::COLORS[:brand]}Sync mode set to: #{mode}#{UI::COLORS[:reset]}"
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  Quarks::CLI.new.run(ARGV)
end
