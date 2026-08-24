require "fileutils"
require "find"
require "pathname"

module Quarks
  module GeneratedPaths
    module_function

    EXACT = %w[
      usr/share/info/dir
      usr/local/share/info/dir
      usr/share/applications/mimeinfo.cache
      usr/local/share/applications/mimeinfo.cache
      usr/share/glib-2.0/schemas/gschemas.compiled
      usr/local/share/glib-2.0/schemas/gschemas.compiled
      usr/share/mime/aliases
      usr/share/mime/generic-icons
      usr/share/mime/globs
      usr/share/mime/globs2
      usr/share/mime/icons
      usr/share/mime/magic
      usr/share/mime/mime.cache
      usr/share/mime/subclasses
      usr/share/mime/treemagic
      usr/share/mime/types
      usr/share/mime/version
      usr/local/share/mime/aliases
      usr/local/share/mime/generic-icons
      usr/local/share/mime/globs
      usr/local/share/mime/globs2
      usr/local/share/mime/icons
      usr/local/share/mime/magic
      usr/local/share/mime/mime.cache
      usr/local/share/mime/subclasses
      usr/local/share/mime/treemagic
      usr/local/share/mime/types
      usr/local/share/mime/version
    ].freeze

    def generated?(path)
      value = normalize(path)
      return false if value.empty?
      return true if EXACT.include?(value)
      return true if value.match?(%r{\Ausr/(?:local/)?share/icons/[^/]+/icon-theme\.cache\z})
      false
    end

    def normalize(path)
      value = path.to_s.tr("\\", "/").sub(%r{\A/+}, "")
      clean = Pathname.new(value).cleanpath.to_s
      return "" if clean == "." || clean == ".." || clean.start_with?("../") || clean.include?("\0")
      clean
    rescue ArgumentError
      ""
    end

    def remove_from_tree!(root)
      base = File.expand_path(root)
      removed = []
      Find.find(base) do |path|
        next if path == base
        stat = File.lstat(path)
        next if stat.directory?
        rel = path.delete_prefix(base).sub(%r{\A/+}, "")
        next unless generated?(rel)
        FileUtils.rm_f(path)
        removed << rel
      end
      removed
    end
  end
end
