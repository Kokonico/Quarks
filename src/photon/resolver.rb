# frozen_string_literal: true

require "set"

module Photon
  class DependencyResolver
    MAX_DEPTH = 500

    def initialize(repository, database)
      @repository = repository
      @database = database
      @resolved = []
      @visited = Set.new
      @stack = []
    end

    def resolve(name_or_atom)
      @resolved = []
      @visited = Set.new
      @stack = []
      resolve_recursive(name_or_atom.to_s, 0)
      @resolved
    end

    private

    def resolve_recursive(name_or_atom, depth)
      raise "Dependency tree too deep (possible cycle)" if depth > MAX_DEPTH

      key = name_or_atom.to_s.strip
      return if key.empty?

      pkg = @repository.find_package(key)
      raise "Package not found: #{key}" unless pkg

      name = pkg.name.to_s.downcase

      if @database.installed?(name)
        UI.info "#{"  " * depth}#{pkg.atom} (already installed)" if ENV["PHOTON_DEBUG"]
        return
      end

      if @stack.include?(pkg.atom)
        cycle = (@stack + [pkg.atom]).join(" -> ")
        raise "Circular dependency detected: #{cycle}"
      end

      return if @visited.include?(pkg.atom)
      @visited.add(pkg.atom)

      UI.info "#{"  " * depth}Resolving #{pkg.atom}..." if ENV["PHOTON_DEBUG"]
      @stack << pkg.atom

      deps = (Array(pkg.dependencies) + Array(pkg.build_dependencies))
             .map(&:to_s).map(&:strip).reject(&:empty?).uniq

      deps.each do |dep|
        resolve_recursive(dep, depth + 1)
      end

      @stack.pop
      @resolved << pkg unless @database.installed?(name)
    end
  end
end
