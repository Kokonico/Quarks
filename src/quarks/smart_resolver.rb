# frozen_string_literal: true

require "set"
require "fileutils"

module Quarks
  class SmartResolver
    class ResolutionError < StandardError
      attr_reader :conflicts

      def initialize(message, conflicts: [])
        super(message)
        @conflicts = conflicts
      end
    end

    class CircularDependencyError < ResolutionError
      attr_reader :cycle

      def initialize(cycle)
        @cycle = cycle
        super("Circular dependency detected: #{cycle.join(' -> ')}")
      end
    end

    class MissingDependencyError < ResolutionError
      attr_reader :package, :dependency

      def initialize(package, dependency)
        @package = package
        @dependency = dependency
        super("Package '#{package}' depends on missing package '#{dependency}'")
      end
    end

    class BlockedPackageError < ResolutionError
      attr_reader :package, :blocker

      def initialize(package, blocker)
        @package = package
        @blocker = blocker
        super("Package '#{package}' is blocked by '#{blocker}'")
      end
    end

    class SlotConflictError < ResolutionError
      def initialize(package, installed, slot)
        super("Package '#{package}' requires slot '#{slot}' but '#{installed}' occupies this slot")
      end
    end

    attr_reader :repository, :database, :use_config
    attr_reader :resolution_order, :conflicts, :conflicts_resolved

    def initialize(repository, database, use_config: nil)
      @repository = repository
      @database = database
      @use_config = use_config || USEConfig.new
      @slot_manager = SLOTManager.new

      @resolution_order = []
      @conflicts = []
      @conflicts_resolved = []
      @visited = Set.new
      @stack = []
      @resolution_context = {}
      @build_deps_mode = false
    end

    def resolve(package_name, build_deps: false, deep: true)
      @build_deps_mode = build_deps
      @resolution_order.clear
      @conflicts.clear
      @conflicts_resolved.clear
      @visited.clear
      @stack.clear

      pkg = @repository.find_package(package_name)
      unless pkg
        raise MissingDependencyError.new(package_name, package_name)
      end

      load_blockers_for_all!
      resolve_recursive(pkg)

      if deep
        @resolution_order.reverse!
      else
        @resolution_order
      end
    end

    def resolve_deps_only(package_name)
      pkg = @repository.find_package(package_name)
      return [] unless pkg

      deps = collect_all_deps(pkg)
      deps.map { |name| @repository.find_package(name) }.compact
    end

    def check_sanity(package)
      issues = []

      issues.concat(check_missing_deps(package))
      issues.concat(check_blockers(package))
      issues.concat(check_slot_conflicts(package))
      issues.concat(check_use_deps(package))
      issues.concat(check_circular_deps(package))

      issues
    end

    def validate_resolution!
      @conflicts.each do |conflict|
        case conflict[:type]
        when :missing_dep
          raise MissingDependencyError.new(conflict[:package], conflict[:dependency])
        when :blocked
          raise BlockedPackageError.new(conflict[:package], conflict[:blocker])
        when :slot_conflict
          raise SlotConflictError.new(
            conflict[:package],
            conflict[:installed],
            conflict[:slot]
          )
        when :circular
          raise CircularDependencyError.new(conflict[:cycle])
        end
      end

      true
    end

    def explain_resolution(package_name)
      pkg = @repository.find_package(package_name)
      return nil unless pkg

      deps = analyze_dependencies(pkg)
      {
        package: pkg.atom,
        version: pkg.version,
        direct_deps: deps[:direct],
        runtime_deps: deps[:runtime],
        build_deps: deps[:build],
        total_deps: deps[:total],
        blockers: deps[:blockers],
        use_flags: deps[:use_flags],
        slot: pkg.slot || "default"
      }
    end

    def suggest_use_flags(package_name)
      pkg = @repository.find_package(package_name)
      return {} unless pkg

      suggestions = {}
      pkg_use_deps ||= []

      if pkg.respond_to?(:use_dependencies)
        pkg_use_deps = Array(pkg.use_dependencies)
      end

      pkg_use_deps.each do |use_dep|
        flag_name = use_dep[:flag]
        dep_packages = Array(use_dep[:dependencies])

        available = dep_packages.select { |d| @repository.find_package(d) }
        suggestions[flag_name] = {
          available: available,
          recommended: available.first
        }
      end

      suggestions
    end

    private

    def load_blockers_for_all!
      @repository.list_atoms.each do |atom|
        pkg = @repository.find_package(atom)
        next unless pkg

        blockers = Array(pkg.blocks)
        blockers.each do |blocked|
          blocked_name = @repository.normalize_name(blocked)
          unless @resolution_context[:blockers]
            @resolution_context[:blockers] = {}
          end
          @resolution_context[:blockers][pkg.atom] ||= []
          @resolution_context[:blockers][pkg.atom] << blocked_name
        end
      end
    end

    def resolve_recursive(package, depth = 0)
      raise ResolutionError, "Dependency tree too deep (max #{MAX_DEPTH})" if depth > MAX_DEPTH

      name = package.name.to_s.downcase
      atom = package.atom.to_s.downcase

      if @stack.include?(atom)
        cycle = @stack[@stack.index(atom)..-1] + [atom]
        raise CircularDependencyError.new(cycle)
      end

      return if @visited.include?(atom)

      @visited.add(atom)
      @stack << atom

      deps = collect_dependencies(package)

      deps.each do |dep_name|
        dep_pkg = @repository.find_package(dep_name)
        unless dep_pkg
          if @build_deps_mode
            next
          else
            @conflicts << {
              type: :missing_dep,
              package: package.atom,
              dependency: dep_name
            }
            next
          end
        end

        if @database.installed?(dep_pkg.name) && !needs_update?(dep_pkg)
          next
        end

        resolve_recursive(dep_pkg, depth + 1)
      end

      @stack.pop
      @resolution_order << package unless @resolution_order.any? { |p| p.atom == package.atom }
    end

    def collect_dependencies(package)
      deps = []

      runtime_deps = expand_use_dependencies(package, Array(package.dependencies))
      build_deps = Array(package.build_dependencies)

      deps.concat(runtime_deps)
      deps.concat(build_deps) if @build_deps_mode

      deps.map { |d| @repository.normalize_name(d) }.uniq
    end

    def expand_use_dependencies(package, base_deps)
      return base_deps unless package.respond_to?(:use_dependencies)

      use_deps = Array(package.use_dependencies)
      return base_deps if use_deps.empty?

      enabled_flags = @use_config.flags_for_package(package.atom)
      expanded = base_deps.dup

      use_deps.each do |use_dep|
        flag = use_dep[:flag]
        flag_deps = Array(use_dep[:dependencies])
        condition = use_dep[:condition] || :enabled

        case condition
        when :enabled
          if enabled_flags.include?(flag.to_s)
            expanded.concat(flag_deps)
          elsif enabled_flags.include?("-#{flag}")
            expanded.concat(flag_deps.map { |d| "-#{d}" })
          end
        when :disabled
          if enabled_flags.include?("-#{flag}")
            expanded.concat(flag_deps)
          end
        end
      end

      expanded
    end

    def collect_all_deps(package)
      deps = []
      deps.concat(Array(package.dependencies))
      deps.concat(Array(package.build_dependencies))

      if package.respond_to?(:use_dependencies)
        package.use_dependencies.each do |use_dep|
          deps.concat(Array(use_dep[:dependencies]))
        end
      end

      deps.map { |d| @repository.normalize_name(d) }.uniq
    end

    def needs_update?(package)
      installed = @database.get_package(package.name)
      return true unless installed

      installed_version = installed[:version]
      available_version = package.version

      version_compare(available_version, installed_version) > 0
    end

    def version_compare(a, b)
      parts_a = parse_version(a)
      parts_b = parse_version(b)
      parts_a <=> parts_b
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

    def check_missing_deps(package)
      issues = []
      deps = Array(package.dependencies) + Array(package.build_dependencies)

      deps.each do |dep|
        dep_name = @repository.normalize_name(dep)
        pkg = @repository.find_package(dep_name)

        unless pkg
          unless @database.installed?(dep_name)
            issues << {
              type: :missing_dep,
              package: package.atom,
              dependency: dep
            }
          end
        end
      end

      issues
    end

    def check_blockers(package)
      return [] unless @resolution_context[:blockers]

      issues = []
      blockers = @resolution_context[:blockers][package.atom] || []

      blockers.each do |blocked_name|
        if @database.installed?(blocked_name)
          installed = @database.get_package(blocked_name)
          issues << {
            type: :blocked,
            package: package.atom,
            blocker: installed ? installed[:atom] : blocked_name
          }
        end
      end

      issues
    end

    def check_slot_conflicts(package)
      return [] unless package.slot
      return [] if package.slot.to_s.empty? || package.slot == "0" || package.slot == "default"

      slot_atoms = @slot_manager.slot_atoms(package.name, package.slot)
      return [] if slot_atoms.empty?

      conflicts = []
      slot_atoms.each do |atom|
        next if atom == package.atom

        pkg = @database.get_package(@repository.normalize_name(atom))
        next unless pkg

        conflicts << {
          type: :slot_conflict,
          package: package.atom,
          installed: pkg[:atom],
          slot: package.slot
        }
      end

      conflicts
    end

    def check_use_deps(package)
      return [] unless package.respond_to?(:use_dependencies)

      issues = []
      use_deps = Array(package.use_dependencies)
      enabled_flags = @use_config.flags_for_package(package.atom)

      use_deps.each do |use_dep|
        flag = use_dep[:flag]
        deps = Array(use_dep[:dependencies])

        deps.each do |dep|
          dep_name = @repository.normalize_name(dep)
          pkg = @repository.find_package(dep_name)

          if pkg && !pkg.respond_to?(:provided_by)
            if enabled_flags.include?(flag.to_s) && !@database.installed?(dep_name)
              issues << {
                type: :use_dep_missing,
                package: package.atom,
                flag: flag,
                dependency: dep
              }
            end
          end
        end
      end

      issues
    end

    def check_circular_deps(package)
      return [] unless @visited.include?(package.atom.to_s.downcase)

      [{
        type: :circular,
        package: package.atom,
        cycle: @stack.dup
      }]
    end

    def analyze_dependencies(package)
      direct = Array(package.dependencies)
      build = Array(package.build_dependencies)
      runtime = direct - build

      all = collect_all_deps(package)
      unique_names = all.map { |d| @repository.normalize_name(d) }.uniq

      blockers = []
      if @resolution_context[:blockers]
        blockers = @resolution_context[:blockers][package.atom] || []
      end

      use_flags = []
      if package.respond_to?(:use_dependencies)
        use_flags = Array(package.use_dependencies).map { |u| u[:flag] }
      end

      {
        direct: direct,
        build: build,
        runtime: runtime,
        total: unique_names,
        blockers: blockers,
        use_flags: use_flags
      }
    end

    MAX_DEPTH = 500
  end

  class ConfigProtection
    PROTECTED_DIRS = [
      "/etc",
      "/var/db"
    ].freeze

    PROTECTED_PATTERNS = [
      /\/etc\/passwd$/,
      /\/etc\/shadow$/,
      /\/etc\/group$/,
      /\/etc\/gshadow$/,
      /\/etc\/shells$/,
      /\/etc\/fstab$/,
      /\/etc\/resolv\.conf$/,
      /\/etc\/hosts\.deny$/,
      /\/etc\/hosts$/,
      /\/etc\/hostname$/,
      /\/etc\/localtime$/,
      /\/etc\/timezone$/,
      /\/etc\/sysctl\.conf$/,
      /\/etc\/modprobe\.d\//,
      /\/etc\/modules$/,
      /\/etc\/udev\/rules\.d\//
    ].freeze

    CONFIG_BACKUP_DIR = File.join(Quarks::Env.state_root, "var", "backup", "quarks")

    def initialize
      @protected = Set.new
      load_protected!
    end

    def protected?(path)
      return true if PROTECTED_PATTERNS.any? { |p| path =~ p }

      PROTECTED_DIRS.any? do |dir|
        path.start_with?(dir) && !path.start_with?("#{dir}/quarks")
      end
    end

    def protect(path)
      @protected.add(File.expand_path(path))
      save_protected!
    end

    def unprotect(path)
      @protected.delete(File.expand_path(path))
      save_protected!
    end

    def protect_file(path)
      return unless protected?(path)

      backup_path = backup_file(path)
      return if File.exist?(backup_path)

      FileUtils.cp(path, backup_path)
      backup_path
    end

    def restore_file(path)
      backup_path = backup_file(path)
      return false unless File.exist?(backup_path)

      FileUtils.cp(backup_path, path)
      true
    end

    def backup_file(path)
      safe_name = path.gsub("/", "_").gsub("\\", "_")
      File.join(CONFIG_BACKUP_DIR, safe_name)
    end

    def list_protected
      @protected.to_a
    end

    def load_protected!
      file = protected_list_file
      return unless File.exist?(file)

      @protected.clear
      File.readlines(file).each do |line|
        line = line.strip
        @protected.add(line) unless line.empty?
      end
    end

    def save_protected!
      FileUtils.mkdir_p(File.dirname(protected_list_file))
      File.write(protected_list_file, @protected.to_a.join("\n"))
    end

    def protected_list_file
      File.join(CONFIG_BACKUP_DIR, "protected.list")
    end
  end
end
