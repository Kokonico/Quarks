# frozen_string_literal: true

require "fileutils"
require "json"
require "quarks/env"
require "quarks/security"

module Quarks
  class USEConfig
    FLAG_PATTERN = /\A-?[A-Za-z0-9][A-Za-z0-9+_@.-]*\z/.freeze
    PACKAGE_PATTERN = /\A(?:\*|[A-Za-z0-9][A-Za-z0-9+_.-]*(?:\/[A-Za-z0-9][A-Za-z0-9+_.-]*)?)\z/.freeze
    SYSTEM_USE = [].freeze

    DEFAULT_USE_FILE = File.join(Quarks::Env.xdg_config_home, "quarks", "use.conf")
    SYSTEM_USE_FILE = "/etc/quarks/use.conf"
    PROFILE_USE_FILE = File.join(Quarks::Env.state_root, "var", "db", "quarks", "profile", "use")

    attr_reader :package_use

    def initialize(config_home: Quarks::Env.xdg_config_home,
                   state_root: Quarks::Env.state_root,
                   system_config_dir: ENV.fetch("QUARKS_SYSTEM_CONFIG_DIR", "/etc/quarks"))
      @user_dir = File.join(File.expand_path(config_home), "quarks")
      @system_dir = File.expand_path(system_config_dir)
      @profile_dir = File.join(File.expand_path(state_root), "var", "db", "quarks", "profile")
      @use_flags = []
      @system_flags = []
      @profile_flags = []
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
      resolve_flags(system_flags + profile_flags + @use_flags + env_flags)
    end

    def system_flags
      @system_flags.dup
    end

    def profile_flags
      @profile_flags.dup
    end

    def env_flags
      parse_flags(ENV["QUARKS_USE"])
    end

    def flags_for_package(package)
      candidates = package_keys(package)
      tokens = expand_use_flags(all_flags)
      candidates.each { |key| tokens.concat(Array(@package_use[key])) }
      tokens = expand_use_flags(tokens)
      state = flag_state(tokens)
      candidates.each { |key| Array(@use_mask[key]).each { |flag| state[flag] = false } }
      candidates.each { |key| Array(@use_force[key]).each { |flag| state[flag] = true } }
      state.map { |flag, enabled| enabled ? flag : "-#{flag}" }
    end

    def masked_flags(package)
      package_keys(package).flat_map { |key| Array(@use_mask[key]) }.uniq
    end

    def forced_flags(package)
      package_keys(package).flat_map { |key| Array(@use_force[key]) }.uniq
    end

    def expand_use_flags(flags)
      expanded = []
      flags.each do |flag|
        if flag.start_with?("-") && @use_expand[flag_name(flag)]
          expanded.concat(@use_expand.fetch(flag_name(flag)).map { |value| "-#{flag_name(value)}" })
        elsif flag.start_with?("-")
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
      @system_flags.clear
      @profile_flags.clear
      @use_expand.clear
      @package_use.clear
      @use_mask.clear
      @use_force.clear

      @system_flags.concat(SYSTEM_USE)
      load_global_file(File.join(@system_dir, "use.conf"), @system_flags)
      load_global_file(File.join(@profile_dir, "use"), @profile_flags)
      load_global_file(File.join(@user_dir, "use.conf"), @use_flags)

      load_package_file(File.join(@system_dir, "package.use"), @package_use)
      load_package_file(File.join(@profile_dir, "package.use"), @package_use)
      load_package_file(File.join(@user_dir, "package.use"), @package_use)
      load_package_file(File.join(@system_dir, "use.mask"), @use_mask, flag_mode: :positive)
      load_package_file(File.join(@profile_dir, "use.mask"), @use_mask, flag_mode: :positive)
      load_package_file(File.join(@user_dir, "use.mask"), @use_mask, flag_mode: :positive)
      load_package_file(File.join(@system_dir, "use.force"), @use_force, flag_mode: :positive)
      load_package_file(File.join(@profile_dir, "use.force"), @use_force, flag_mode: :positive)
      load_package_file(File.join(@user_dir, "use.force"), @use_force, flag_mode: :positive)
      self
    end

    def save!
      write_global_file(File.join(@user_dir, "use.conf"), @use_flags)
      write_package_file(File.join(@user_dir, "package.use"), @package_use)
      write_package_file(File.join(@user_dir, "use.mask"), @use_mask)
      write_package_file(File.join(@user_dir, "use.force"), @use_force)
      true
    end

    def add_flag(flag)
      token = validate_flag!(flag)
      replace_flag!(@use_flags, token)
    end

    def remove_flag(flag)
      name = flag_name(validate_flag!(flag))
      @use_flags.reject! { |token| flag_name(token) == name }
    end

    def replace_global_flags(flags)
      @use_flags = resolve_flags(Array(flags).map { |flag| validate_flag!(flag) })
    end

    def set_package_flags(package, flags)
      key = validate_package!(package)
      @package_use[key] = resolve_flags(Array(flags).map { |flag| validate_flag!(flag) })
    end

    def mask_package_flag(package, flag)
      add_package_rule(@use_mask, package, flag)
    end

    def force_package_flag(package, flag)
      add_package_rule(@use_force, package, flag)
    end

    def unmask_package_flag(package, flag)
      remove_package_rule(@use_mask, package, flag)
    end

    def unforce_package_flag(package, flag)
      remove_package_rule(@use_force, package, flag)
    end

    private

    def package_keys(package)
      atom = package.respond_to?(:atom) ? package.atom.to_s : package.to_s
      name = package.respond_to?(:name) ? package.name.to_s : atom.split("/", 2).last.to_s
      ["*", name, atom].reject(&:empty?).uniq
    end

    def parse_flags(value)
      value.to_s.split.map { |flag| validate_flag!(flag) }
    end

    def flag_name(flag)
      flag.to_s.delete_prefix("-")
    end

    def flag_state(flags)
      flags.each_with_object({}) do |token, state|
        name = flag_name(token)
        state.delete(name)
        state[name] = !token.start_with?("-")
      end
    end

    def resolve_flags(flags)
      flag_state(flags).map { |name, enabled| enabled ? name : "-#{name}" }
    end

    def replace_flag!(list, flag)
      name = flag_name(flag)
      list.reject! { |token| flag_name(token) == name }
      list << flag
    end

    def validate_flag!(flag)
      value = flag.to_s.strip
      raise ArgumentError, "Invalid USE flag: #{flag.inspect}" unless value.match?(FLAG_PATTERN)
      value
    end

    def validate_package!(package)
      value = package.to_s.strip
      raise ArgumentError, "Invalid package atom: #{package.inspect}" unless value.match?(PACKAGE_PATTERN)
      value
    end

    def add_package_rule(table, package, flag)
      key = validate_package!(package)
      name = flag_name(validate_flag!(flag))
      table[key] ||= []
      table[key] << name unless table[key].include?(name)
    end

    def remove_package_rule(table, package, flag)
      key = validate_package!(package)
      name = flag_name(validate_flag!(flag))
      Array(table[key]).delete(name)
      table.delete(key) if table[key]&.empty?
    end

    def meaningful_lines(path)
      return [] unless File.file?(path)
      mode = File.stat(path).mode
      raise ArgumentError, "Refusing group/world-writable USE configuration: #{path}" if (mode & 0o022).positive?
      File.foreach(path).filter_map do |line|
        value = line.sub(/\s+#.*\z/, "").strip
        value unless value.empty? || value.start_with?("#")
      end
    rescue Errno::ENOENT
      []
    end

    def load_global_file(path, destination)
      meaningful_lines(path).each do |line|
        if line.start_with?("expand ")
          _directive, key, *values = line.split
          @use_expand[validate_flag!(key)] = values.map { |flag| validate_flag!(flag) }
        elsif line.include?(":")
          key, values = line.split(":", 2)
          @use_expand[validate_flag!(key)] = parse_flags(values)
        else
          parse_flags(line).each { |flag| replace_flag!(destination, flag) }
        end
      end
    end

    def load_package_file(path, destination, flag_mode: :signed)
      meaningful_lines(path).each do |line|
        package, *flags = line.split
        raise ArgumentError, "Missing flags in #{path}: #{line.inspect}" if flags.empty?
        key = validate_package!(package)
        destination[key] ||= []
        flags.each do |flag|
          token = validate_flag!(flag)
          token = flag_name(token) if flag_mode == :positive
          if flag_mode == :signed
            replace_flag!(destination[key], token)
          else
            destination[key] << token unless destination[key].include?(token)
          end
        end
      end
    end

    def write_global_file(path, flags)
      lines = ["# Global USE flags. Prefix a flag with '-' to disable it."]
      lines << resolve_flags(flags).join(" ") unless flags.empty?
      Quarks::Security.atomic_write(path, "#{lines.join("\n")}\n", mode: 0o644)
    end

    def write_package_file(path, table)
      lines = ["# Format: package-or-category/package flag -disabled-flag"]
      table.sort.each do |package, flags|
        next if flags.empty?
        lines << "#{package} #{flags.join(" ")}"
      end
      Quarks::Security.atomic_write(path, "#{lines.join("\n")}\n", mode: 0o644)
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
      Quarks::Security.atomic_write(SLOT_FILE, JSON.pretty_generate({
        slots: @slots,
        slot_atoms: @slot_atoms
      }))
    end

    def load!
      return unless File.exist?(SLOT_FILE)

      data = JSON.parse(File.read(SLOT_FILE))
      raise ArgumentError, "Slot database must contain an object" unless data.is_a?(Hash)
      @slots = data["slots"] || {}
      @slot_atoms = data["slot_atoms"] || {}
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid slot database #{SLOT_FILE}: #{e.message}"
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
