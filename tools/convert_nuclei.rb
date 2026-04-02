#!/usr/bin/env ruby
require 'yaml'

Dir.glob('nuclei/*.nuclei').each do |file|
  content = File.read(file)
  next unless content.strip.start_with?('name:')
  
  lines = content.lines
  
  name = nil
  version = nil
  sources = []
  build_deps = []
  build_cmds = []
  
  i = 0
  while i < lines.length
    line = lines[i].strip
    if line.start_with?('name:')
      name = line.sub('name:', '').strip
    elsif line.start_with?('version:')
      version = line.sub('version:', '').strip
    elsif line.start_with?('- https://') || line.start_with?('- http://')
      url = line.sub(/^-\s*/, '').strip
      sources << url
      # Check if next line is checksum
      if i + 1 < lines.length && lines[i + 1].strip.start_with?('checksum:')
        i += 1
      end
    elsif line.start_with?('build:')
      # Collect build commands
      i += 1
      while i < lines.length && lines[i].strip.start_with?('-')
        cmd = lines[i].strip.sub(/^-\s*/, '')
        build_cmds << cmd unless cmd.start_with?('checksum:')
        i += 1
      end
      next
    elsif line.start_with?('build_dependencies:')
      i += 1
      while i < lines.length && lines[i].strip.start_with?('-')
        dep = lines[i].strip.sub(/^-\s*/, '')
        build_deps << dep unless dep.start_with?('checksum:')
        i += 1
      end
      next
    end
    i += 1
  end
  
  name ||= File.basename(file, '.nuclei')
  version ||= '0.0.1'
  
  # Generate Ruby DSL
  source_lines = sources.map { |s| "source \"#{s}\",\n         checksum: \"placeholder...\",\n         algorithm: \"sha256\"" }
  source_str = source_lines.join("\n\n  ")
  
  build_deps_str = build_deps.map { |d| "\"#{d}\"" }.join(', ')
  build_lines = build_cmds.map { |c| "run \"#{c}\"" }
  build_str = build_lines.join("\n    ")
  
  dsl = "nuclei \"#{name}\", \"#{version}\" do\n" \
        "  description \"#{name} package\"\n" \
        "  homepage \"\"\n" \
        "  license \"Unknown\"\n" \
        "  category \"app\"\n\n" \
        "  #{source_str}\n\n" \
        "  depends #{build_deps_str.empty? ? '[]' : build_deps_str}\n\n" \
        "  build_depends #{build_deps_str}\n\n" \
        "  build do\n" \
        "    #{build_str}\n" \
        "  end\n" \
        "end\n"
  
  File.write(file, dsl)
  puts "Converted: #{file}"
end
puts "Done"
