# frozen_string_literal: true

require "fileutils"
require "json"

module Quarks
  class USEConfig
    DEFAULT_USE_FILE = File.join(Quarks::Env.xdg_config_home, "quarks", "use.conf")
    SYSTEM_USE_FILE = "/etc/quarks/use.conf"
    MAKE_CONF_USE = ENV["QUARKS_USE"].to_s.split

    SYSTEM_USE = %w[
      static-libs
    ].freeze

    PROFILE_USE_FILE = File.join(Quarks::Env.state_root, "var", "db", "quarks", "profile", "use")

    def initialize
      @use_flags = []
      @use_expand = {}
      @package_use = {}
      @use_mask = {}
      @use_force = {}
      load!
    end

    def flags
      @use_flags.dup
    end

    def all_flags
      (system_flags + profile_flags + env_flags + @use_flags).compact.uniq
    end

    def system_flags
      SYSTEM_USE.dup
    end

    def profile_flags
      return [] unless File.exist?(PROFILE_USE_FILE)

      File.readlines(PROFILE_USE_FILE)
          .reject { |l| l.start_with?("#") || l.strip.empty? }
          .map { |l| l.strip.split }
          .flatten
          .uniq
    rescue
      []
    end

    def env_flags
      MAKE_CONF_USE.dup
    end

    def flags_for_package(package_name)
      pkg_flags = @package_use[package_name] || []
      pkg_flags - masked_flags(package_name) + forced_flags(package_name)
    end

    def masked_flags(package_name)
      masks = []
      masks += @use_mask["*"] || []
      masks += @use_mask[package_name] || []
      masks
    end

    def forced_flags(package_name)
      forces = []
      forces += @use_force["*"] || []
      forces += @use_force[package_name] || []
      forces
    end

    def expand_use_flags(flags)
      expanded = []
      flags.each do |flag|
        if flag.start_with?("-")
          expanded << flag
        elsif @use_expand[flag]
          expanded.concat(@use_expand[flag])
        else
          expanded << flag
        end
      end
      expanded
    end

    def use_expand_flags
      @use_expand.dup
    end

    def load!
      @use_flags.clear
      @use_expand.clear
      @package_use.clear
      @use_mask.clear
      @use_force.clear

      load_system_use!
      load_user_use!
      load_package_use!
    end

    def save!
      FileUtils.mkdir_p(File.dirname(DEFAULT_USE_FILE))

      lines = []
      lines << "# Quarks USE flags configuration"
      lines << "# One flag per line, use -flag to disable"
      lines << ""

      @use_flags.each { |f| lines << f unless f.start_with?("-") }
      @use_flags.select { |f| f.start_with?("-") }.each { |f| lines << f }

      lines << ""
      lines << "# Package-specific flags (package.use format)"
      @package_use.each do |pkg, flags|
        lines << "#{pkg} #{flags.join(" ")}"
      end

      File.write(DEFAULT_USE_FILE, lines.join("\n"))
    end

    def add_flag(flag)
      flag = flag.to_s.strip
      return if flag.empty?
      @use_flags << flag unless @use_flags.include?(flag)
    end

    def remove_flag(flag)
      @use_flags.delete(flag.to_s.strip)
      @use_flags.delete("-#{flag}")
    end

    def set_package_flags(package, flags)
      @package_use[package.to_s] = flags.map(&:to_s)
    end

    def mask_package_flag(package, flag)
      @use_mask[package.to_s] ||= []
      @use_mask[package.to_s] << flag unless @use_mask[package.to_s].include?(flag)
    end

    def force_package_flag(package, flag)
      @use_force[package.to_s] ||= []
      @use_force[package.to_s] << flag unless @use_force[package.to_s].include?(flag)
    end

    private

    def load_system_use!
      return unless File.exist?(SYSTEM_USE_FILE)

      File.readlines(SYSTEM_USE_FILE).each do |line|
        parse_use_line(line)
      end
    end

    def load_user_use!
      return unless File.exist?(DEFAULT_USE_FILE)

      File.readlines(DEFAULT_USE_FILE).each do |line|
        parse_use_line(line)
      end
    end

    def load_package_use!
      package_use_file = File.join(Quarks::Env.xdg_config_home, "quarks", "package.use")
      return unless File.exist?(package_use_file)

      File.readlines(package_use_file).each do |line|
        next if line.start_with?("#")
        next if line.strip.empty?

        parts = line.strip.split
        next if parts.length < 2

        package = parts[0]
        flags = parts[1..-1]
        @package_use[package] ||= []
        @package_use[package].concat(flags)
      end
    end

    def parse_use_line(line)
      line = line.strip
      return if line.empty?
      return if line.start_with?("#")

      if line.include?(" ")
        parts = line.split
        package = parts[0]
        flags = parts[1..-1]
        @package_use[package] ||= []
        @package_use[package].concat(flags)
      elsif line.include?(":")
        key, values = line.split(":", 2)
        @use_expand[key] ||= []
        @use_expand[key].concat(values.split)
      elsif line.start_with?("*")
        @use_mask["*"] ||= []
        @use_mask["*"] << line[1..-1]
      elsif line =~ /^[a-zA-Z0-9_-]+\/[a-zA-Z0-9_.-]+$/
        parts = line.split
        @package_use[parts[0]] ||= []
        @package_use[parts[0]].concat(parts[1..-1]) if parts.length > 1
      else
        @use_flags << line unless @use_flags.include?(line)
      end
    end
  end

  class SLOTManager
    SLOT_FILE = File.join(Quarks::Env.state_root, "var", "db", "quarks", "slot_mapping.json")

    def initialize
      @slots = {}
      @slot_atoms = {}
      load!
    end

    def register(package, slot)
      return if slot.nil? || slot.to_s.empty? || slot == "0"

      slot_str = slot.to_s
      name = package.name.to_s.downcase

      @slots[name] ||= {}
      @slots[name][slot_str] ||= []

      unless @slots[name][slot_str].include?(package.atom)
        @slots[name][slot_str] << package.atom
      end

      @slot_atoms[package.atom] = slot_str
      save!
    end

    def unregister(package_name, slot)
      name = package_name.to_s.downcase
      slot_str = slot.to_s

      return unless @slots[name]

      if slot_str.empty?
        @slots[name].each do |s, atoms|
          atoms.each { |a| @slot_atoms.delete(a) }
        end
        @slots.delete(name)
      else
        atoms = @slots[name][slot_str] || []
        atoms.each { |a| @slot_atoms.delete(a) }
        @slots[name].delete(slot_str)
        @slots.delete(name) if @slots[name].empty?
      end

      save!
    end

    def get_slot(package_name)
      @slots[package_name.to_s.downcase]
    end

    def slot_for_atom(atom)
      @slot_atoms[atom.to_s]
    end

    def slots_for_package(package_name)
      @slots[package_name.to_s.downcase] || {}
    end

    def slot_atoms(package_name, slot)
      @slots.dig(package_name.to_s.downcase, slot.to_s) || []
    end

    def has_slot_conflict?(package_name, slot)
      slot_atoms = slot_atoms(package_name, slot)
      return false if slot_atoms.empty?

      slot_atoms.any? do |atom|
        yield(atom) if block_given?
        true
      end
    end

    def default_slot?(slot)
      slot.nil? || slot.empty? || slot == "0" || slot == "default"
    end

    def save!
      FileUtils.mkdir_p(File.dirname(SLOT_FILE))
      File.write(SLOT_FILE, JSON.pretty_generate({
        slots: @slots,
        slot_atoms: @slot_atoms
      }))
    end

    def load!
      return unless File.exist?(SLOT_FILE)

      data = JSON.parse(File.read(SLOT_FILE))
      @slots = data["slots"] || {}
      @slot_atoms = data["slot_atoms"] || {}
    rescue
      @slots = {}
      @slot_atoms = {}
    end

    def inspect
      "#<SLOTManager #{@slots.length} packages with slots>"
    end
  end

  class BlockerManager
    def initialize(repository, database)
      @repository = repository
      @database = database
      @blockers = {}
      @blocked_by = {}
    end

    def load_blockers!(package)
      return unless package.respond_to?(:blocks)

      blocks = Array(package.blocks)
      return if blocks.empty?

      @blockers[package.atom] ||= []
      @blockers[package.atom].concat(blocks.map(&:to_s))
    end

    def check_blockers(package)
      conflicts = []
      blocks = @blockers[package.atom] || []

      blocks.each do |blocked|
        blocked_name = @repository.normalize_name(blocked)

        if @database.installed?(blocked_name)
          pkg = @database.get_package(blocked_name)
          conflicts << {
            type: :blocks,
            package: package.atom,
            blocked: pkg ? pkg[:atom] : blocked,
            message: "#{package.atom} blocks #{blocked}"
          }
        end
      end

      reverse_blockers(package).each do |blocker|
        conflicts << {
          type: :blocked_by,
          package: package.atom,
          blocker: blocker,
          message: "#{blocker} blocks #{package.atom}"
        }
      end

      conflicts
    end

    def reverse_blockers(package)
      blocked = []
      @blockers.each do |atom, blocks|
        next unless blocks.include?(package.name) || blocks.include?(package.atom)

        pkg = @database.get_package(@repository.normalize_name(atom))
        blocked << (pkg ? pkg[:atom] : atom)
      end
      blocked
    end

    def resolve_blocker!(conflict)
      case conflict[:type]
      when :blocks
        raise BlockedPackageError,
          "Cannot install #{conflict[:package]}: it blocks #{conflict[:blocked]}"
      when :blocked_by
        raise BlockedPackageError,
          "Cannot install #{conflict[:package]}: blocked by #{conflict[:blocker]}"
      end
    end

    def clear!
      @blockers.clear
      @blocked_by.clear
    end
  end

  class BlockedPackageError < StandardError; end
end
