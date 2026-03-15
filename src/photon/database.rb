# frozen_string_literal: true

require "sqlite3"
require "json"
require "fileutils"
require "digest"
require "time"
require "photon/env"

module Photon
  class Database
    PHOTON_ROOT = Env.root.freeze
    STATE_ROOT  = Env.state_root.freeze

    DB_PATH    = File.join(STATE_ROOT, "var", "db", "photon.sqlite3").freeze
    CACHE_ROOT = File.join(STATE_ROOT, "var", "cache", "photon").freeze
    LOG_ROOT   = File.join(STATE_ROOT, "var", "log", "photon").freeze

    SCHEMA_VERSION = 4

    class << self
      def original_user = Env.original_user
      def original_user_home = Env.home_for
    end

    def initialize
      ensure_dirs!
      open_db!
      configure_db!
      migrate!
      @ready = true
    rescue SQLite3::Exception => e
      recover_or_raise!(e)
    end

    def ready?
      !!@ready
    end

    def normalize_name(name_or_atom)
      value = name_or_atom.to_s.strip
      return "" if value.empty?
      value = value.split("/", 2).last if value.include?("/")
      value.downcase
    end

    def installed?(name_or_atom)
      name = normalize_name(name_or_atom)
      return false if name.empty?
      !@db.get_first_value("SELECT 1 FROM packages WHERE name=? LIMIT 1", [name]).nil?
    rescue
      false
    end

    def list_packages
      @db.execute("SELECT name FROM packages ORDER BY name ASC").map { |row| row["name"] || row[0] }
    rescue
      []
    end

    def get_package(name_or_atom)
      name = normalize_name(name_or_atom)
      return nil if name.empty?

      row = @db.get_first_row("SELECT * FROM packages WHERE name=? LIMIT 1", [name])
      return nil unless row

      files = @db.execute("SELECT path FROM files WHERE package_name=? ORDER BY path ASC", [name]).map { |r| r["path"] || r[0] }

      {
        name: row["name"],
        version: row["version"],
        atom: row["atom"],
        category: row["category"],
        installed_at: row["installed_at"],
        install_time: row["install_time"],
        metadata: decode_json(row["metadata_json"]),
        files: files
      }
    rescue
      nil
    end

    def add_package(package, files:, install_time: nil)
      raise "Database not ready" unless ready?

      pkg_name = normalize_name(package&.name)
      raise "Invalid package name" if pkg_name.empty?

      version = package&.version.to_s.strip
      version = "0.0.0" if version.empty?

      atom = package.respond_to?(:atom) ? package.atom.to_s.strip : pkg_name
      atom = pkg_name if atom.empty?

      category = package.respond_to?(:category) ? package.category.to_s.strip : "app"
      category = "app" if category.empty?

      metadata_hash = package.respond_to?(:to_metadata) ? package.to_metadata : { name: pkg_name, version: version, atom: atom, category: category }

      rel_files = Array(files).map { |path| normalize_rel_path(path) }.reject(&:empty?).uniq.sort
      collisions = find_collisions(rel_files, exclude_package: pkg_name)
      if collisions.any?
        preview = collisions.first(15).map { |c| "  #{c[:path]} (owned by #{c[:owner]})" }.join("\n")
        more = collisions.length > 15 ? "\n  ... (#{collisions.length - 15} more)" : ""
        raise <<~MSG.strip
          File collision detected while merging #{atom}!

          The following files are already owned by other packages:
          #{preview}#{more}
        MSG
      end

      installed_at = Time.now.to_i
      metadata_json = JSON.generate(metadata_hash)

      transaction do
        @db.execute(<<~SQL, [pkg_name, version, atom, category, installed_at, install_time, metadata_json])
          INSERT INTO packages(name, version, atom, category, installed_at, install_time, metadata_json)
          VALUES(?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(name) DO UPDATE SET
            version=excluded.version,
            atom=excluded.atom,
            category=excluded.category,
            installed_at=excluded.installed_at,
            install_time=excluded.install_time,
            metadata_json=excluded.metadata_json;
        SQL

        @db.execute("DELETE FROM files WHERE package_name=?", [pkg_name])
        rel_files.each do |rel|
          @db.execute("INSERT INTO files(path, package_name) VALUES(?, ?)", [rel, pkg_name])
        end
      end

      true
    end

    def remove_package(name_or_atom)
      info = get_package(name_or_atom)
      return false unless info

      name = info[:name]
      atom = info[:atom].to_s.strip

      transaction do
        @db.execute("DELETE FROM files WHERE package_name=?", [name])
        @db.execute("DELETE FROM packages WHERE name=?", [name])
        world_remove(atom) unless atom.empty?
        world_remove(name)
      end

      true
    rescue
      false
    end

    def world_add(atom)
      value = atom.to_s.strip
      return false if value.empty?
      @db.execute("INSERT OR IGNORE INTO world(atom) VALUES(?)", [value])
      true
    rescue
      false
    end

    def world_remove(name_or_atom)
      value = name_or_atom.to_s.strip
      return false if value.empty?

      if value.include?("/")
        @db.execute("DELETE FROM world WHERE atom=?", [value])
      else
        @db.execute("DELETE FROM world WHERE atom=? OR atom LIKE ?", [value, "%/#{value}"])
      end

      true
    rescue
      false
    end

    alias add_to_world world_add
    alias remove_from_world world_remove

    def world_list
      @db.execute("SELECT atom FROM world ORDER BY atom ASC").map { |row| row["atom"] || row[0] }
    rescue
      []
    end

    def owner_of(path)
      rel = normalize_lookup_path(path)
      return nil if rel.empty?

      row = @db.get_first_row(<<~SQL, [rel])
        SELECT p.name, p.atom, p.version, f.path
        FROM files f
        JOIN packages p ON p.name = f.package_name
        WHERE f.path=?
        LIMIT 1
      SQL
      return nil unless row

      { name: row["name"], atom: row["atom"], version: row["version"], path: row["path"] }
    rescue
      nil
    end

    def which_command(cmd)
      value = File.basename(cmd.to_s.strip)
      return nil if value.empty?

      candidates = [
        "bin/#{value}", "sbin/#{value}",
        "usr/bin/#{value}", "usr/sbin/#{value}",
        "usr/local/bin/#{value}", "usr/local/sbin/#{value}"
      ]

      row = @db.get_first_row(<<~SQL, candidates)
        SELECT p.name, p.atom, p.version, f.path
        FROM files f
        JOIN packages p ON p.name = f.package_name
        WHERE f.path IN (?, ?, ?, ?, ?, ?)
        LIMIT 1
      SQL
      return nil unless row

      { name: row["name"], atom: row["atom"], version: row["version"], path: File.join(PHOTON_ROOT, row["path"]) }
    rescue
      nil
    end

    def installed_binaries
      out = {}

      @db.execute("SELECT path FROM files ORDER BY path ASC").each do |row|
        rel = normalize_rel_path(row["path"] || row[0])
        next if rel.empty?
        next unless binary_rel_path?(rel)

        name = File.basename(rel)
        abs = File.join(PHOTON_ROOT, rel)
        next unless File.exist?(abs) || File.symlink?(abs)
        next unless (File.executable?(abs) rescue true)

        out[name] ||= abs
      end

      out
    rescue
      {}
    end

    def find_collisions(files, exclude_package: nil)
      rel_files = Array(files).map { |path| normalize_rel_path(path) }.reject(&:empty?).uniq
      return [] if rel_files.empty?

      collisions = []
      rel_files.each do |rel|
        owner = @db.get_first_value("SELECT package_name FROM files WHERE path=? LIMIT 1", [rel]) rescue nil
        next if owner.nil?
        next if exclude_package && owner.to_s == normalize_name(exclude_package)
        collisions << { path: rel, owner: owner.to_s }
      end

      collisions
    rescue
      []
    end

    def cache_dirs
      [CACHE_ROOT, File.join(STATE_ROOT, "var", "tmp", "photon")].uniq
    end

    def compact!
      @db.execute("PRAGMA optimize;") rescue nil
      @db.execute("VACUUM;")
      true
    rescue
      false
    end

    def stats
      {
        page_count: (@db.get_first_value("PRAGMA page_count;") rescue 0).to_i,
        freelist_count: (@db.get_first_value("PRAGMA freelist_count;") rescue 0).to_i,
        page_size: (@db.get_first_value("PRAGMA page_size;") rescue 0).to_i,
        user_version: (@db.get_first_value("PRAGMA user_version;") rescue 0).to_i
      }
    rescue
      { page_count: 0, freelist_count: 0, page_size: 0, user_version: 0 }
    end

    private

    def ensure_dirs!
      FileUtils.mkdir_p(File.dirname(DB_PATH))
      FileUtils.mkdir_p(CACHE_ROOT)
      FileUtils.mkdir_p(LOG_ROOT)
    end

    def open_db!
      @db = SQLite3::Database.new(DB_PATH)
      @db.results_as_hash = true
    end

    def configure_db!
      @db.busy_timeout = 5_000 rescue nil
      @db.execute("PRAGMA foreign_keys = ON;") rescue nil
      @db.execute("PRAGMA journal_mode = WAL;") rescue nil
      @db.execute("PRAGMA synchronous = NORMAL;") rescue nil
      @db.execute("PRAGMA temp_store = MEMORY;") rescue nil
    end

    def migrate!
      create_meta_table!
      create_packages_table!
      create_files_table!
      create_world_table!
      create_indexes!
      write_schema_version(SCHEMA_VERSION)
      @db.execute("PRAGMA user_version = #{SCHEMA_VERSION};") rescue nil
      true
    end

    def create_meta_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS meta(
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      SQL
    end

    def create_packages_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS packages(
          name TEXT PRIMARY KEY,
          version TEXT NOT NULL,
          atom TEXT,
          category TEXT,
          installed_at INTEGER,
          install_time REAL,
          metadata_json TEXT
        );
      SQL
    end

    def create_files_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS files(
          path TEXT PRIMARY KEY,
          package_name TEXT NOT NULL,
          FOREIGN KEY(package_name) REFERENCES packages(name) ON DELETE CASCADE
        );
      SQL
    end

    def create_world_table!
      @db.execute(<<~SQL)
        CREATE TABLE IF NOT EXISTS world(
          atom TEXT PRIMARY KEY
        );
      SQL
    end

    def create_indexes!
      @db.execute("CREATE INDEX IF NOT EXISTS idx_files_pkg ON files(package_name);")
      @db.execute("CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);")
      @db.execute("CREATE INDEX IF NOT EXISTS idx_packages_atom ON packages(atom);")
      @db.execute("CREATE INDEX IF NOT EXISTS idx_packages_name ON packages(name);")
    end

    def write_schema_version(version)
      @db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)", [version.to_i.to_s])
    rescue
      nil
    end

    def recover_or_raise!(error)
      message = "#{error.class}: #{error.message}"

      if File.exist?(DB_PATH)
        FileUtils.cp(DB_PATH, "#{DB_PATH}.bak.#{Time.now.to_i}") rescue nil
        FileUtils.mv(DB_PATH, "#{DB_PATH}.broken.#{Time.now.to_i}") rescue nil
      end

      open_db!
      configure_db!
      migrate!
      @ready = true
      warn "[photon] Database recovered from error: #{message}" if Env.debug?
    rescue => e
      raise "Database failed to recover: #{message} (recovery error: #{e.class}: #{e.message})"
    end

    def transaction
      @db.transaction
      yield
      @db.commit
    rescue => e
      @db.rollback rescue nil
      raise e
    end

    def normalize_rel_path(path)
      value = path.to_s.strip
      value = value.sub(%r{^/+}, "")
      value.tr!("\\", "/")
      value
    end

    def normalize_lookup_path(path)
      value = path.to_s.strip
      return "" if value.empty?

      expanded = File.expand_path(value)
      root = File.expand_path(PHOTON_ROOT)

      if expanded.start_with?(root + "/")
        normalize_rel_path(expanded.delete_prefix(root + "/"))
      else
        normalize_rel_path(value)
      end
    rescue
      normalize_rel_path(path)
    end

    def decode_json(value)
      return {} if value.nil? || value.to_s.strip.empty?
      JSON.parse(value.to_s, symbolize_names: true)
    rescue
      {}
    end

    def binary_rel_path?(rel)
      rel.start_with?("bin/") ||
        rel.start_with?("sbin/") ||
        rel.start_with?("usr/bin/") ||
        rel.start_with?("usr/sbin/") ||
        rel.start_with?("usr/local/bin/") ||
        rel.start_with?("usr/local/sbin/")
    end
  end
end
