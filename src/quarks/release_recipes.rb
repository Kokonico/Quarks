# frozen_string_literal: true

require "quarks/package"

module Quarks
  module ReleaseRecipes
    Result = Struct.new(:packages, :paths, :excluded, keyword_init: true)
    module_function

    def load(paths)
      entries = []
      excluded = []

      Array(paths).sort.each do |path|
        package = Quarks::Package.load_from_nuclei(path)
        entries << [path, package]
      rescue Quarks::NucleiError => e
        excluded << { path: path, error: e.message, type: :schema }
      end

      duplicate_names = entries.group_by { |_path, package| package.name.downcase }
                               .select { |_name, values| values.length > 1 }
      duplicate_names.each_value do |values|
        values.each { |path, _package| excluded << { path: path, error: "duplicate package name", type: :duplicate } }
      end
      entries.reject! { |_path, package| duplicate_names.key?(package.name.downcase) }

      available = entries.to_h { |_path, package| [package.name.downcase, true] }
      loop do
        unresolved = entries.select do |_path, package|
          dependencies(package).any? { |dependency| !available.key?(dependency) }
        end
        break if unresolved.empty?

        unresolved.each do |path, package|
          missing = dependencies(package).reject { |dependency| available.key?(dependency) }
          excluded << {
            path: path,
            error: "unresolved dependencies: #{missing.join(', ')}",
            type: :dependency
          }
        end
        entries -= unresolved
        unresolved.each { |_path, package| available.delete(package.name.downcase) }
      end

      Result.new(
        paths: entries.map(&:first),
        packages: entries.map(&:last),
        excluded: excluded
      )
    end

    def dependencies(package)
      conditional = Array(package.use_dependencies).flat_map do |use_dependency|
        Array(use_dependency[:dependencies] || use_dependency["dependencies"])
      end
      (Array(package.dependencies) + Array(package.build_dependencies) + conditional).map do |dependency|
        dependency.to_s.split("/", 2).last.downcase
      end.uniq
    end
  end
end
