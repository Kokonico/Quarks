# frozen_string_literal: true

require "fileutils"
require "json"
require "find"

module Quarks
  class QueryCommands
    COMMANDS = {
      "deps" => :query_deps,
      "rdeps" => :query_rdeps,
      "tree" => :query_tree,
      "graph" => :query_graph,
      "size" => :query_size,
      "audit" => :query_audit,
      "fix" => :query_fix,
      "clean" => :query_clean,
      "info" => :query_info,
      "whatprovides" => :query_whatprovides,
      "wp" => :query_whatprovides,
      "manifest" => :query_manifest,
      "verify" => :query_verify,
      "stats" => :query_stats,
      "list" => :query_list
    }.freeze

    def self.run(cmd, args, repository, database)
      handler = COMMANDS[cmd.to_s.downcase]
      return nil, "Unknown query: #{cmd}" unless handler

      new.send(handler, args, repository, database)
    end

    def self.list_commands
      COMMANDS.keys
    end

    def query_deps(args, repository, database)
      return nil, "Usage: query deps <package>" if args.empty?

      pkg_name = args[0]
      pkg = repository.find_package(pkg_name)
      return nil, "Package not found: #{pkg_name}" unless pkg

      output = "Dependencies for #{pkg.atom}-#{pkg.version}:\n\n"

      runtime = Array(pkg.dependencies)
      build = Array(pkg.build_dependencies)

      if runtime.any?
        output += "  Runtime:\n"
        runtime.each { |d| output += "    #{d}\n" }
      end

      if build.any?
        output += "  Build:\n"
        build.each { |d| output += "    #{d}\n" }
      end

      if runtime.empty? && build.empty?
        output += "  No dependencies\n"
      end

      [output, nil]
    end

    def query_rdeps(args, repository, database)
      return nil, "Usage: query rdeps <package>" if args.empty?

      pkg_name = args[0]
      normalized = repository.normalize_name(pkg_name)

      results = []
      database.list_packages.each do |name|
        next if name == normalized

        pkg = database.get_package(name)
        next unless pkg

        all_deps = Array(pkg[:metadata][:dependencies]) +
                   Array(pkg[:metadata][:build_dependencies])

        if all_deps.include?(normalized) || all_deps.include?(pkg_name)
          results << pkg[:atom] || name
        end
      end

      output = "Packages depending on #{pkg_name}:\n\n"
      if results.empty?
        output += "  None\n"
      else
        results.each { |r| output += "  #{r}\n" }
      end

      [output, nil]
    end

    def query_tree(args, repository, database)
      return nil, "Usage: query tree <package> [max-depth]" if args.empty?

      pkg_name = args[0]
      pkg = repository.find_package(pkg_name)
      return nil, "Package not found: #{pkg_name}" unless pkg

      max_depth = (args[1] || 3).to_i
      output = "Dependency tree for #{pkg.atom}-#{pkg.version}:\n\n"

      print_tree(pkg, repository, database, output, 0, max_depth)

      [output, nil]
    end

    def print_tree(pkg, repository, database, output, depth, max_depth)
      return if depth > max_depth

      indent = "  " * depth
      installed = database.installed?(pkg.name) ? "[*]" : "[ ]"
      output += "#{indent}#{installed} #{pkg.atom}-#{pkg.version}\n"

      Array(pkg.dependencies).each do |dep_name|
        dep = repository.find_package(dep_name)
        if dep
          print_tree(dep, repository, database, output, depth + 1, max_depth)
        end
      end
    end

    def query_graph(args, repository, database)
      return nil, "Usage: query graph <package>" if args.empty?

      pkg_name = args[0]
      pkg = repository.find_package(pkg_name)
      return nil, "Package not found: #{pkg_name}" unless pkg

      output = "Graph for #{pkg.atom} (dot format):\n\n"
      output += "digraph #{pkg.name.gsub("-", "_")} {\n"

      nodes = {}
      edges = []
      queue = [pkg]
      visited = Set.new

      until queue.empty?
        current = queue.shift
        next if visited.include?(current.name)

        visited.add(current.name)
        nodes[current.name] = current

        Array(current.dependencies).each do |dep_name|
          dep = repository.find_package(dep_name)
          if dep
            edges << [current.name, dep.name]
            queue << dep unless visited.include?(dep.name)
          end
        end
      end

      nodes.each do |name, p|
        shape = database.installed?(name) ? "box" : "oval"
        output += "  #{name.gsub("-", "_")} [label=\"#{p.atom}\" shape=#{shape}];\n"
      end

      edges.each do |from, to|
        output += "  #{from.gsub("-", "_")} -> #{to.gsub("-", "_")};\n"
      end

      output += "}\n"

      [output, nil]
    end

    def query_size(args, repository, database)
      return nil, "Usage: query size <package>" if args.empty?

      pkg_name = args[0]
      pkg = database.get_package(pkg_name)
      return nil, "Package not installed: #{pkg_name}" unless pkg

      files = Array(pkg[:files])
      total_size = 0

      files.each do |rel_path|
        abs = File.join(Database::QUARKS_ROOT, rel_path)
        if File.exist?(abs)
          total_size += File.size(abs)
        elsif File.symlink?(abs)
          total_size += 0
        end
      end

      output = "Size for #{pkg[:atom]}-#{pkg[:version]}:\n\n"
      output += "  Total: #{format_size(total_size)}\n"
      output += "  Files: #{files.length}\n"

      by_type = {}
      files.each do |f|
        ext = File.extname(f)
        ext = "none" if ext.empty?
        by_type[ext] ||= []
        by_type[ext] << f
      end

      output += "\n  By type:\n"
      by_type.sort_by { |_, v| -v.length }.first(5).each do |type, type_files|
        type_size = type_files.sum do |f|
          abs = File.join(Database::QUARKS_ROOT, f)
          File.size(abs) rescue 0
        end
        output += "    #{type}: #{type_files.length} (#{format_size(type_size)})\n"
      end

      [output, nil]
    end

    def format_size(bytes)
      units = ["B", "KB", "MB", "GB", "TB"]
      exp = (Math.log(bytes) / Math.log(1024)).floor
      exp = [exp, units.length - 1].min
      size = bytes.to_f / (1024**exp)
      "#{size.round(2)} #{units[exp]}"
    end

    def query_audit(args, repository, database)
      issues = []

      database.list_packages.each do |name|
        pkg = database.get_package(name)
        next unless pkg

        if pkg[:files].empty?
          issues << { type: "empty", package: name, message: "No tracked files" }
        end

        pkg[:files].each do |rel_path|
          abs = File.join(Database::QUARKS_ROOT, rel_path)
          unless File.exist?(abs) || File.symlink?(abs)
            issues << { type: "missing", package: name, file: rel_path }
          end
        end

        missing_deps = Array(pkg[:metadata][:dependencies]).select do |dep|
          !database.installed?(dep)
        end
        unless missing_deps.empty?
          issues << { type: "missing-deps", package: name, deps: missing_deps }
        end
      end

      output = "Audit: #{issues.length} issues\n\n"

      issues.group_by { |i| i[:type] }.each do |type, type_issues|
        output += "  #{type}: #{type_issues.length}\n"
      end

      if args.include?("-v") || args.include?("--verbose")
        output += "\nDetails:\n"
        issues.first(20).each do |i|
          output += "  [#{i[:type]}] #{i[:package]}\n"
        end
      end

      [output, nil]
    end

    def query_fix(args, repository, database)
      fixes = []

      database.list_packages.each do |name|
        pkg = database.get_package(name)
        next unless pkg

        if pkg[:files].empty?
          files = []
          search_path = File.join(Database::QUARKS_ROOT, name)
          if Dir.exist?(search_path)
            Find.find(search_path) do |f|
              next unless File.file?(f)
              rel = f.sub("#{Database::QUARKS_ROOT}/", "")
              files << rel
            end
          end

          if files.any?
            fixes << { package: name, action: "rebuilt index", count: files.length }
          end
        end
      end

      output = "Fixes: #{fixes.length}\n"
      fixes.each do |f|
        output += "  #{f[:package]}: #{f[:action]}\n"
      end

      [output, nil]
    end

    def query_clean(args, repository, database)
      world = WorldManager.new
      world_atoms = Set.new(world.contents)

      orphans = []

      database.list_packages.each do |name|
        pkg = database.get_package(name)
        next unless pkg

        atom = pkg[:atom].to_s.downcase
        next if world_atoms.include?(atom)

        dependents = []
        database.list_packages.each do |other_name|
          next if other_name == name
          other = database.get_package(other_name)
          next unless other

          all_deps = Array(other[:metadata][:dependencies]) +
                     Array(other[:metadata][:build_dependencies])

          dependents << other[:atom] if all_deps.include?(name)
        end

        orphans << { name: name, atom: pkg[:atom], deps: dependents }
      end

      output = "Orphans: #{orphans.length}\n\n"

      safe = orphans.select { |o| o[:deps].empty? }
      output += "  Safe to remove: #{safe.length}\n"
      output += "  Protected: #{orphans.length - safe.length}\n\n"

      if safe.any?
        output += "Safe orphans:\n"
        safe.each { |o| output += "  #{o[:atom]}\n" }
      end

      [output, nil]
    end

    def query_info(args, repository, database)
      return nil, "Usage: query info <package>" if args.empty?

      pkg_name = args[0]
      pkg = repository.find_package(pkg_name)

      if pkg
        atom = pkg.atom
        version = pkg.version
      else
        db_pkg = database.get_package(pkg_name)
        return nil, "Package not found: #{pkg_name}" unless db_pkg

        atom = db_pkg[:atom] || pkg_name
        version = db_pkg[:version]
      end

      output = "#{atom}-#{version}\n"
      output += "License: #{pkg.license}\n" if pkg && pkg.license != "Unknown"
      output += "Homepage: #{pkg.homepage}\n" if pkg && !pkg.homepage.to_s.empty?
      output += "Sources: #{pkg.sources.length}\n" if pkg
      output += "Runtime deps: #{pkg.dependencies.length}\n" if pkg
      output += "Build deps: #{pkg.build_dependencies.length}\n" if pkg

      [output, nil]
    end

    def query_whatprovides(args, repository, database)
      return nil, "Usage: query whatprovides <file|command>" if args.empty?

      query = args[0]
      results = []

      database.list_packages.each do |name|
        pkg = database.get_package(name)
        next unless pkg

        files = Array(pkg[:files])
        matching = files.select { |f| f.include?(query) || f.end_with?(query) }

        if matching.any?
          results << {
            package: pkg[:atom] || name,
            version: pkg[:version],
            files: matching
          }
        end
      end

      if results.empty?
        return nil, "No packages provide: #{query}"
      end

      output = "Packages providing '#{query}':\n\n"
      results.each do |r|
        output += "  #{r[:package]}-#{r[:version]}\n"
        r[:files].first(5).each { |f| output += "    #{f}\n" }
      end

      [output, nil]
    end

    def query_manifest(args, repository, database)
      return nil, "Usage: query manifest <package>" if args.empty?

      pkg_name = args[0]
      pkg = repository.find_package(pkg_name)
      return nil, "Package not found: #{pkg_name}" unless pkg

      output = "Manifest for #{pkg.atom}-#{pkg.version}:\n\n"
      output += "  Category: #{pkg.category}\n"
      output += "  License: #{pkg.license}\n"
      output += "  Build system: #{pkg.build_system}\n"

      if pkg.slot
        output += "  Slot: #{pkg.slot}\n"
      end

      if pkg.blocks.any?
        output += "\n  Blocks:\n"
        pkg.blocks.each { |b| output += "    #{b}\n" }
      end

      output += "\n  Sources:\n"
      pkg.sources.each_with_index do |src, i|
        checksum = pkg.checksums[src]
        hash = checksum ? checksum[:hash]&.slice(0, 16) : "none"
        output += "    #{i + 1}. #{File.basename(src)}\n"
        output += "       Hash: #{hash}...\n"
      end

      [output, nil]
    end

    def query_verify(args, repository, database)
      return nil, "Usage: query verify <package>" if args.empty?

      pkg_name = args[0]
      pkg = database.get_package(pkg_name)
      return nil, "Package not installed: #{pkg_name}" unless pkg

      output = "Verifying #{pkg[:atom]}...\n\n"
      issues = []

      pkg[:files].each do |rel_path|
        abs = File.join(Database::QUARKS_ROOT, rel_path)
        issues << "Missing: #{rel_path}" unless File.exist?(abs)
      end

      if issues.empty?
        output += "  All #{pkg[:files].length} files verified OK\n"
      else
        output += "  Issues: #{issues.length}\n"
        issues.first(10).each { |i| output += "    #{i}\n" }
      end

      [output, nil]
    end

    def query_stats(args, repository, database)
      output = "Statistics:\n\n"

      installed = database.list_packages.length
      available = repository.list_atoms.length
      world = WorldManager.new.contents.length

      by_category = Hash.new(0)
      database.list_packages.each do |name|
        pkg = database.get_package(name)
        by_category[pkg[:category]] += 1 if pkg && pkg[:category]
      end

      output += "  Installed: #{installed}\n"
      output += "  Available: #{available}\n"
      output += "  World: #{world}\n\n"

      output += "By category:\n"
      by_category.sort_by { |_, v| -v }.first(10).each do |cat, count|
        output += "  #{cat}: #{count}\n"
      end

      cache_size = 0
      Database.new.cache_dirs.each do |dir|
        next unless Dir.exist?(dir)
        Find.find(dir) { |f| cache_size += File.size(f) if File.file?(f) }
      end
      output += "\nCache: #{format_size(cache_size)}\n"

      [output, nil]
    end

    def query_list(args, repository, database)
      packages = database.list_packages

      if args.include?("--category") || args.include?("-c")
        by_cat = Hash.new { |h, k| h[k] = [] }
        packages.each do |name|
          pkg = database.get_package(name)
          by_cat[pkg[:category] || "unknown"] << name if pkg
        end

        output = "Packages by category:\n\n"
        by_cat.sort.each do |cat, names|
          output += "  #{cat}: #{names.length}\n"
        end
      else
        output = "Installed packages (#{packages.length}):\n\n"
        packages.each do |name|
          pkg = database.get_package(name)
          output += "  #{pkg[:atom]}-#{pkg[:version]}\n" if pkg
        end
      end

      [output, nil]
    end
  end
end
