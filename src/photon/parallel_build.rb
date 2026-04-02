# frozen_string_literal: true

require "thread"
require "fileutils"

module Photon
  class ParallelBuilder
    class BuildError < StandardError
      attr_reader :package, :log_file

      def initialize(message, package: nil, log_file: nil)
        super(message)
        @package = package
        @log_file = log_file
      end
    end

    def initialize(jobs: Photon::Env.jobs, options: {})
      @max_jobs = [jobs.to_i, 1].max
      @options = options || {}
      @queue = Queue.new
      @results = []
      @mutex = Mutex.new
      @running = 0
      @failed = []
      @succeeded = []
      @semaphore = Concurrent::Semaphore.new(@max_jobs)
    rescue NameError
      @semaphore = nil
      @max_jobs = 1
    end

    def build_packages(packages)
      return sequential_build(packages) if @max_jobs == 1 || !parallel_possible?

      packages.each { |pkg| @queue.push(pkg) }

      threads = @max_jobs.times.map do |i|
        Thread.new do
          Thread.current[:worker_id] = i
          process_queue
        end
      end

      threads.each(&:join)

      @results
    end

    def sequential_build(packages)
      packages.each_with_index.map do |package, index|
        begin
          result = build_single(package, index + 1, packages.length)
          @succeeded << package
          result
        rescue => e
          @failed << { package: package, error: e }
          raise e unless @options[:keep_going]
          nil
        end
      end.compact
    end

    private

    def parallel_possible?
      return false unless @semaphore

      packages = []
      @queue.size.times { packages << @queue.pop(true) }
      packages.each { |pkg| @queue.push(pkg) }

      packages.all? do |pkg|
        !has_dependencies?(pkg, packages)
      end
    end

    def has_dependencies?(package, all_packages)
      deps = Array(package.dependencies) + Array(package.build_dependencies)
      deps.any? do |dep|
        all_packages.any? { |p| p.name.to_s.downcase == dep.to_s.downcase }
      end
    end

    def process_queue
      loop do
        package = @queue.pop(true)
      rescue ThreadError
        break
      end

      begin
        if @semaphore
          @semaphore.acquire
        end

        @mutex.synchronize { @running += 1 }

        result = build_single(package, @succeeded.length + @failed.length + 1, @succeeded.length + @failed.length + @queue.size + 1)

        @mutex.synchronize do
          @succeeded << package
          @results << result
        end
      rescue => e
        @mutex.synchronize do
          @failed << { package: package, error: e }
        end
      ensure
        if @semaphore
          @semaphore.release
        end
        @mutex.synchronize { @running -= 1 }
      end
    end

    def build_single(package, current, total)
      builder = Builder.new(package, current, total, @options.merge(jobs: 1))
      dest_dir = builder.build
      { package: package, dest_dir: dest_dir, success: true }
    end

    def succeeded
      @succeeded.dup
    end

    def failed
      @failed.dup
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

      order.reverse
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
      return if path.include?(name)

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
      order << name unless @visited[name] == :done
      @visited[name] = :done
    end

    def detect_cycle(name)
      return :permanent if @visited[name] == :permanent
      return if @visited[name] == :processing

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
        owner_pkg = @database.get_package(collision[:owner])
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

module Concurrent
  class Semaphore
    def initialize permits
      @permits = permits
      @mutex = Mutex.new
      @condition = ConditionVariable.new
    end

    def acquire
      @mutex.synchronize do
        while @permits.zero?
          @condition.wait(@mutex)
        end
        @permits -= 1
      end
    end

    def release
      @mutex.synchronize do
        @permits += 1
        @condition.broadcast
      end
    end

    def try_acquire
      @mutex.synchronize do
        if @permits > 0
          @permits -= 1
          true
        else
          false
        end
      end
    end
  end
end
