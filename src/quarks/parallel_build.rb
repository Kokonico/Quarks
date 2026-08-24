# frozen_string_literal: true

require "thread"
require "fileutils"
require "quarks/source_size"

module Quarks
  class ParallelBuilder
    attr_reader :succeeded, :failed

    def initialize(max_jobs: nil, options: {})
      requested = max_jobs.to_i
      requested = Quarks::Env.jobs unless requested.positive?
      @max_jobs = [[requested, 1].max, 1024].min
      @options = options || {}
      @mutex = Mutex.new
      @succeeded = []
      @failed = []
      @source_size_tracker = Quarks::SourceSize.new
    end

    def build_packages(packages)
      packages = Array(packages)
      reset_results!
      return [] if packages.empty?
      return sequential_build(packages) if @max_jobs == 1 || !parallel_possible?(packages)

      queue = Queue.new
      packages.each_with_index { |package, index| queue << [index, package] }
      results = Array.new(packages.length)
      stop = false

      workers = [@max_jobs, packages.length].min.times.map do
        Thread.new do
          loop do
            break if @mutex.synchronize { stop }
            begin
              index, package = queue.pop(true)
            rescue ThreadError
              break
            end

            begin
              result = build_single(package, index + 1, packages.length)
              @mutex.synchronize do
                @succeeded << package
                results[index] = result
              end
            rescue => e
              @mutex.synchronize do
                @failed << { package: package, error: e, index: index }
                stop = true unless @options[:keep_going]
              end
            end
          end
        end
      end
      workers.each(&:join)

      first_failure = @mutex.synchronize { @failed.min_by { |failure| failure[:index] } }
      raise first_failure[:error] if first_failure && !@options[:keep_going]
      results.compact
    end

    def sequential_build(packages)
      packages.each_with_index.filter_map do |package, index|
        begin
          result = build_single(package, index + 1, packages.length)
          @succeeded << package
          result
        rescue => e
          @failed << { package: package, error: e, index: index }
          raise unless @options[:keep_going]
          nil
        end
      end
    end

    private

    def reset_results!
      @succeeded = []
      @failed = []
    end

    def parallel_possible?(packages)
      names = packages.each_with_object({}) do |package, out|
        out[dependency_name(package.name)] = true
      end
      packages.none? do |package|
        dependencies = Array(package.dependencies) + Array(package.build_dependencies)
        dependencies.any? { |dependency| names[dependency_name(dependency)] }
      end
    end

    def dependency_name(value)
      value.to_s.downcase.split("/", 2).last.to_s
    end

    def build_single(package, current, total)
      builder = Builder.new(package, current, total, @options.merge(jobs: 1, source_size_tracker: @source_size_tracker))
      dest_dir = builder.build
      { package: package, dest_dir: dest_dir, success: true }
    end
  end

  class DependencyGraph
    class CycleError < StandardError
      attr_reader :cycle

      def initialize(message, cycle:)
        super(message)
        @cycle = cycle
      end
    end

    def initialize(repository, database)
      @repository = repository
      @database = database
      @graph = {}
      @visited = {}
      @rec_stack = []
    end

    def add_package(package)
      name = package.name.to_s.downcase
      @graph[name] ||= { package: package, deps: [] }

      deps = Array(package.dependencies) + Array(package.build_dependencies)
      deps.each do |dep|
        dep_name = @repository.normalize_name(dep).to_s
        next if dep_name.empty?

        @graph[name][:deps] << dep_name

        unless @graph[dep_name]
          @graph[dep_name] = { package: nil, deps: [] }
        end
      end
    end

    def resolve_build_order
      order = []
      @visited.clear

      @graph.keys.each do |name|
        visit_node(name, [], order)
      end

      order
    end

    def check_for_cycles
      @visited.clear
      @rec_stack = []

      @graph.keys.each do |name|
        detect_cycle(name)
      end

      true
    rescue CycleError => e
      raise e
    end

    private

    def visit_node(name, path, order)
      return if @visited[name] == :permanent

      if @visited[name] == :temporary
        cycle = path[path.index(name)..-1] + [name]
        raise CycleError.new("Circular dependency detected: #{cycle.join(' -> ')}", cycle: cycle)
      end

      @visited[name] = :temporary
      path = path + [name]

      @graph[name][:deps].each do |dep|
        visit_node(dep, path, order)
      end

      @visited[name] = :permanent
      order << name
    end

    def detect_cycle(name)
      return :permanent if @visited[name] == :permanent

      if @visited[name] == :processing
        cycle = @rec_stack[@rec_stack.index(name)..-1] + [name]
        raise CycleError.new("Circular dependency detected", cycle: cycle)
      end

      @visited[name] = :processing
      @rec_stack << name

      (@graph[name][:deps] || []).each do |dep|
        detect_cycle(dep)
      end

      @visited[name] = :permanent
      @rec_stack.pop
    end
  end

  class ConflictResolver
    class ConflictError < StandardError
      attr_reader :conflicts

      def initialize(message, conflicts:)
        super(message)
        @conflicts = conflicts
      end
    end

    BLOCKING_CONFLICTS = %w[
      sys-libs/ncurses dev-libs/openssl sys-devel/gcc
      sys-libs/glibc dev-lang/ruby dev-lang/python
    ].freeze

    def initialize(repository, database)
      @repository = repository
      @database = database
    end

    def check_blocking_conflicts(package)
      conflicts = []
      name = package.name.to_s.downcase

      BLOCKING_CONFLICTS.each do |blocked|
        next unless name.include?(blocked)

        conflicts << {
          type: :blocking,
          package: package.atom,
          message: "Package '#{package.atom}' conflicts with critical system package '#{blocked}'"
        }
      end

      conflicts
    end

    def check_reverse_dependencies(package)
      conflicts = []
      installed = @database.list_packages

      installed.each do |installed_name|
        pkg = @database.get_package(installed_name)
        next unless pkg

        all_deps = Array(pkg[:metadata][:dependencies]) +
                   Array(pkg[:metadata][:build_dependencies])

        all_deps.each do |dep|
          dep_name = @repository.normalize_name(dep).to_s
          if dep_name == package.name.to_s.downcase
            conflicts << {
              type: :reverse_dependency,
              package: pkg[:atom],
              dependency: package.atom,
              message: "Installed package '#{pkg[:atom]}' depends on '#{package.atom}'"
            }
          end
        end
      end

      conflicts
    end

    def check_file_collisions(package, installed_files)
      collisions = @database.find_collisions(installed_files, exclude_package: package.name)

      collisions.map do |collision|
        owner_pkg = @database.package_summary(collision[:owner])
        {
          type: :file_collision,
          package: package.atom,
          owner: collision[:owner],
          owner_atom: owner_pkg ? owner_pkg[:atom] : collision[:owner],
          file: collision[:path],
          message: "File '#{collision[:path]}' is owned by '#{collision[:owner]}'"
        }
      end
    end

    def check_slot_conflicts(package)
      conflicts = []
      return conflicts unless package.respond_to?(:slot)

      slot = package.slot.to_s
      return conflicts if slot.empty? || slot == "0" || slot == "default"

      installed_same_slot = []
      @database.list_packages.each do |name|
        pkg = @database.get_package(name)
        next unless pkg
        next unless pkg[:metadata][:slot].to_s == slot

        installed_same_slot << pkg[:atom]
      end

      unless installed_same_slot.empty?
        conflicts << {
          type: :slot_conflict,
          package: package.atom,
          slot: slot,
          installed: installed_same_slot,
          message: "Package '#{package.atom}' requires slot '#{slot}' but other packages using this slot are installed: #{installed_same_slot.join(', ')}"
        }
      end

      conflicts
    end

    def resolve_conflict!(conflict)
      case conflict[:type]
      when :file_collision
        raise ConflictError.new(conflict[:message], conflicts: [conflict])
      when :reverse_dependency
        raise ConflictError.new(
          "Cannot remove '#{conflict[:package]}' because '#{conflict[:dependency]}' depends on it",
          conflicts: [conflict]
        )
      when :blocking
        raise ConflictError.new(conflict[:message], conflicts: [conflict])
      when :slot_conflict
        raise ConflictError.new(conflict[:message], conflicts: [conflict])
      else
        raise ConflictError.new("Unknown conflict type: #{conflict[:type]}", conflicts: [conflict])
      end
    end

    def check_and_raise!(package, installed_files = [])
      all_conflicts = []

      all_conflicts.concat(check_blocking_conflicts(package))
      all_conflicts.concat(check_reverse_dependencies(package))
      all_conflicts.concat(check_slot_conflicts(package))

      unless installed_files.empty?
        all_conflicts.concat(check_file_collisions(package, installed_files))
      end

      return if all_conflicts.empty?

      raise ConflictError.new(
        "Conflicts detected for package '#{package.atom}'",
        conflicts: all_conflicts
      )
    end
  end
end
