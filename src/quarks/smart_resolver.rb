# frozen_string_literal: true

require "set"
require "fileutils"
require "quarks/version"

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
      @resolution_order = []
      @conflicts = []
      @conflicts_resolved = []
      @visited = Set.new
      @selected_names = Set.new
      @stack = []
      @build_deps_mode = false
      @dependency_details_cache = {}
      @dependency_atoms_cache = {}
    end

    def resolve(package_name, build_deps: true, deep: true)
      resolve_all([package_name], build_deps: build_deps, deep: deep)
    end

    def resolve_all(package_names, build_deps: true, deep: true)
      @build_deps_mode = build_deps
      @resolution_order.clear
      @conflicts.clear
      @conflicts_resolved.clear
      @visited.clear
      @selected_names.clear
      @stack.clear
      @dependency_details_cache.clear
      @dependency_atoms_cache.clear

      requested = Array(package_names).map(&:to_s).reject(&:empty?).uniq
      packages = requested.map do |package_name|
        pkg = @repository.find_package(package_name)
        raise MissingDependencyError.new(package_name, package_name) unless pkg
        pkg
      end

      packages.each { |package| resolve_recursive(package) }
      validate_resolution!

      deep ? @resolution_order : packages
    end

    def dependency_atoms_for(package)
      atom = package.atom.to_s.downcase
      @dependency_atoms_cache[atom] ||= dependency_details_for(package).map { |dependency| dependency[:atom] }.freeze
      @dependency_atoms_cache[atom].dup
    end

    def dependency_details_for(package)
      atom = package.atom.to_s.downcase
      cached = @dependency_details_cache[atom]
      return cached.map(&:dup) if cached

      dependencies = []
      expand_use_dependencies(package, Array(package.dependencies)).each do |dependency|
        dependencies << [dependency, :runtime]
      end
      if @build_deps_mode
        Array(package.build_dependencies).each { |dependency| dependencies << [dependency, :build] }
      end

      details = dependencies.filter_map do |dependency, type|
        resolved = @repository.find_package(@repository.normalize_name(dependency))
        { atom: resolved.atom, type: type } if resolved
      end.uniq.freeze
      @dependency_details_cache[atom] = details
      details.map(&:dup)
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

    def resolve_recursive(package, depth = 0)
      raise ResolutionError, "Dependency tree too deep (max #{MAX_DEPTH})" if depth > MAX_DEPTH

      atom = package.atom.to_s.downcase
      validate_required_use!(package)

      blocker_issues = blocker_conflicts_for(package)
      @conflicts.concat(blocker_issues)

      if @stack.include?(atom)
        cycle = @stack[@stack.index(atom)..-1] + [atom]
        raise CircularDependencyError.new(cycle)
      end

      return if @visited.include?(atom)

      @visited.add(atom)
      @selected_names.add(package.name.to_s.downcase)
      @stack << atom

      deps = collect_dependencies(package)

      deps.each do |dep_name|
        dep_pkg = @repository.find_package(dep_name)
        unless dep_pkg
          next if @database.installed?(dep_name)
          @conflicts << {
            type: :missing_dep,
            package: package.atom,
            dependency: dep_name
          }
          next
        end

        if @database.installed?(dep_pkg.name) && !needs_update?(dep_pkg)
          next
        end

        resolve_recursive(dep_pkg, depth + 1)
      end

      @stack.pop
      @resolution_order << package
    end

    def collect_dependencies(package)
      deps = []

      runtime_deps = expand_use_dependencies(package, Array(package.dependencies))
      build_deps = Array(package.build_dependencies)

      deps.concat(runtime_deps)
      deps.concat(build_deps) if @build_deps_mode

      deps.map { |d| @repository.normalize_name(d) }.uniq
    end

    def validate_required_use!(package)
      requirements = Array(package.required_use).map(&:to_s)
      return if requirements.empty?

      enabled = @use_config.flags_for_package(package).reject { |flag| flag.start_with?("-") }.to_set
      unmet = requirements.reject do |requirement|
        if requirement.start_with?("-")
          !enabled.include?(requirement.delete_prefix("-"))
        else
          enabled.include?(requirement)
        end
      end
      return if unmet.empty?

      raise ResolutionError, "#{package.atom} has unmet required USE flags: #{unmet.join(' ')}"
    end

    def expand_use_dependencies(package, base_deps)
      return base_deps unless package.respond_to?(:use_dependencies)

      use_deps = Array(package.use_dependencies)
      return base_deps if use_deps.empty?

      enabled_flags = @use_config.flags_for_package(package.atom).reject { |flag| flag.start_with?("-") }.to_set
      expanded = base_deps.dup

      use_deps.each do |use_dep|
        flag = use_dep[:flag]
        flag_deps = Array(use_dep[:dependencies])
        condition = use_dep[:condition] || :enabled

        case condition
        when :enabled
          if enabled_flags.include?(flag.to_s)
            expanded.concat(flag_deps)
          end
        when :disabled
          unless enabled_flags.include?(flag.to_s)
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
      installed = @database.package_summary(package.name)
      return true unless installed

      installed_version = installed[:version]
      available_version = package.version

      Quarks::Versioning.newer?(available_version, installed_version)
    end

    def version_compare(a, b)
      Quarks::Versioning.compare(a, b)
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
      issues = []
      package_atom = package.atom.to_s.downcase

      Array(package.blocks).each do |blocked|
        blocked_name = @repository.normalize_name(blocked).to_s.downcase
        next if blocked_name.empty?
        if @database.installed?(blocked_name) || @selected_names.include?(blocked_name)
          installed = @database.package_summary(blocked_name)
          issues << {
            type: :blocked,
            package: package.atom,
            blocker: installed ? installed[:atom] : blocked.to_s
          }
        end
      end

      @repository.blockers_for(package.name).each do |blocker_atom|
        blocker_name = @repository.normalize_name(blocker_atom).to_s.downcase
        next if blocker_atom.to_s.downcase == package_atom
        next unless @database.installed?(blocker_name) || @visited.include?(blocker_atom.to_s.downcase)

        issues << { type: :blocked, package: package.atom, blocker: blocker_atom }
      end
      issues.uniq
    end

    def blocker_conflicts_for(package)
      check_blockers(package)
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

      blockers = Array(package.blocks).map(&:to_s)

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

end
