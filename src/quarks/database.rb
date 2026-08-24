# frozen_string_literal: true

require "sqlite3"
require "json"
require "fileutils"
require "digest"
require "time"
require "pathname"
require "quarks/env"
require "quarks/generated_paths"
require "quarks/security"

module Quarks
  class Database
    class DatabaseError < StandardError; end
    QUARKS_ROOT = Env.root.freeze
    STATE_ROOT  = Env.state_root.freeze

    DB_PATH    = File.join(STATE_ROOT, "var", "db", "quarks.sqlite3").freeze
    CACHE_ROOT = File.join(STATE_ROOT, "var", "cache", "quarks").freeze
    LOG_ROOT   = File.join(STATE_ROOT, "var", "log", "quarks").freeze

    SCHEMA_VERSION = 6

    class << self
      def original_user = Env.original_user
      def original_user_home = Env.home_for
    end

    def initialize
      ensure_dirs!
      open_db!
      configure_db!
      migrate!
      @package_summary_cache = nil
      @ready = true
    rescue SQLite3::Exception => e
      raise DatabaseError, "Could not open or migrate #{DB_PATH}: #{e.message}. The database was left untouched."
    end

    def ready?
      !!@ready
    end

    def close
      @db&.close
      @ready = false
      true
    end

    def normalize_name(name_or_atom)
      value = name_or_atom.to_s.strip
      return "" if value.empty?
      slash = value.index("/")
      value = value[(slash + 1)..] if slash
      value.downcase
    end

    def installed?(name_or_atom)
      name = normalize_name(name_or_atom)
      return false if name.empty?
      package_summaries.key?(name)
    end

    def list_packages
      package_summaries.keys.sort
    end

    def package_summary(name_or_atom)
      name = normalize_name(name_or_atom)
      return nil if name.empty?
      summary = package_summaries[name]
      summary&.dup
    end

    def list_package_metadata
      @db.execute("SELECT name, version, atom, category, metadata_json FROM packages ORDER BY name ASC").map do |row|
        {
          name: row["name"],
          version: row["version"],
          atom: row["atom"],
          category: row["category"],
          metadata: decode_json(row["metadata_json"])
        }
      end
    end

    def get_package(name_or_atom)
      name = normalize_name(name_or_atom)
      return nil if name.empty?

      row = @db.get_first_row("SELECT * FROM packages WHERE name=? LIMIT 1", [name])
      return nil unless row

      manifest = @db.execute(
        "SELECT path, sha256, size, mode, kind FROM files WHERE package_name=? ORDER BY path ASC",
        [name]
      ).map do |file_row|
        normalize_file_entry({
          path: normalize_rel_path!(file_row["path"] || file_row[0]),
          sha256: file_row["sha256"],
          size: file_row["size"],
          mode: file_row["mode"],
          kind: file_row["kind"]
        })
      end

      {
        name: row["name"],
        version: row["version"],
        atom: row["atom"],
        category: row["category"],
        installed_at: row["installed_at"],
        install_time: row["install_time"],
        metadata: decode_json(row["metadata_json"]),
        files: manifest.map { |entry| entry[:path] },
        file_manifest: manifest,
        world: !@db.get_first_value("SELECT 1 FROM world WHERE atom=? LIMIT 1", [row["atom"]]).nil?
      }
    end

    def add_package(package, files:, install_time: nil, world: false)
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

      file_manifest = Array(files).map { |entry| normalize_file_entry(entry) }
                                  .reject { |entry| GeneratedPaths.generated?(entry[:path]) }
                                  .uniq { |entry| entry[:path] }
                                  .sort_by { |entry| entry[:path] }
      rel_files = file_manifest.map { |entry| entry[:path] }
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
      existing = @db.get_first_row("SELECT atom FROM packages WHERE name=? LIMIT 1", [pkg_name])
      existing_atom = existing && (existing["atom"] || existing[0]).to_s
      existing_world = !existing_atom.to_s.empty? && !@db.get_first_value("SELECT 1 FROM world WHERE atom=? LIMIT 1", [existing_atom]).nil?

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
        insert_file_manifest!(pkg_name, file_manifest)
        @db.execute("DELETE FROM world WHERE atom=?", [existing_atom]) if !existing_atom.to_s.empty? && existing_atom != atom
        @db.execute("INSERT OR IGNORE INTO world(atom) VALUES(?)", [atom]) if world || existing_world
      end

      if @package_summary_cache
        @package_summary_cache[pkg_name] = { name: pkg_name, version: version, atom: atom, category: category }.freeze
      end
      true
    end

    def remove_package(name_or_atom)
      lookup_name = normalize_name(name_or_atom)
      return false if lookup_name.empty?

      row = @db.get_first_row("SELECT name, atom FROM packages WHERE name=? LIMIT 1", [lookup_name])
      return false unless row

      name = (row["name"] || row[0]).to_s
      atom = (row["atom"] || row[1]).to_s.strip

      transaction do
        @db.execute("DELETE FROM files WHERE package_name=?", [name])
        @db.execute("DELETE FROM packages WHERE name=?", [name])
        world_remove(atom) unless atom.empty?
        world_remove(name)
      end

      @package_summary_cache.delete(name.downcase) if @package_summary_cache
      true
    end

    def restore_package(snapshot)
      raise "Database not ready" unless ready?
      raise ArgumentError, "Invalid package snapshot" unless snapshot.is_a?(Hash) && snapshot[:name]

      transaction do
        current_atom = @db.get_first_value("SELECT atom FROM packages WHERE name=? LIMIT 1", [snapshot[:name]]).to_s
        params = [
          snapshot[:name], snapshot[:version], snapshot[:atom], snapshot[:category],
          snapshot[:installed_at], snapshot[:install_time], JSON.generate(snapshot[:metadata] || {})
        ]
        @db.execute(<<~SQL, params)
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
        @db.execute("DELETE FROM files WHERE package_name=?", [snapshot[:name]])
        entries = snapshot[:file_manifest] || Array(snapshot[:files])
        file_manifest = Array(entries).map { |entry| normalize_file_entry(entry) }
                                      .reject { |entry| GeneratedPaths.generated?(entry[:path]) }
                                      .uniq { |entry| entry[:path] }
        insert_file_manifest!(snapshot[:name], file_manifest)
        @db.execute("DELETE FROM world WHERE atom=?", [current_atom]) unless current_atom.empty? || current_atom == snapshot[:atom].to_s
        if snapshot[:world]
          @db.execute("INSERT OR IGNORE INTO world(atom) VALUES(?)", [snapshot[:atom]])
        else
          @db.execute("DELETE FROM world WHERE atom=?", [snapshot[:atom]])
        end
      end
      if @package_summary_cache
        name = snapshot[:name].to_s.downcase
        @package_summary_cache[name] = { name: snapshot[:name], version: snapshot[:version], atom: snapshot[:atom], category: snapshot[:category] }.freeze
      end
      true
    end

    def world_add(atom)
      value = atom.to_s.strip
      return false if value.empty?
      @db.execute("INSERT OR IGNORE INTO world(atom) VALUES(?)", [value])
      true
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
    end

    alias add_to_world world_add
    alias remove_from_world world_remove

    def world_list
      @db.execute("SELECT atom FROM world ORDER BY atom ASC").map { |row| row["atom"] || row[0] }
    end

    def owner_of(path)
      rel = normalize_lookup_path(path)
      return nil if rel.empty? || GeneratedPaths.generated?(rel)

      row = @db.get_first_row(<<~SQL, [rel])
        SELECT p.name, p.atom, p.version, f.path
        FROM files f
        JOIN packages p ON p.name = f.package_name
        WHERE f.path=?
        LIMIT 1
      SQL
      return nil unless row

      { name: row["name"], atom: row["atom"], version: row["version"], path: row["path"] }
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

      { name: row["name"], atom: row["atom"], version: row["version"], path: File.join(QUARKS_ROOT, row["path"]) }
    end

    def installed_binaries
      out = {}

      @db.execute("SELECT path FROM files ORDER BY path ASC").each do |row|
        rel = normalize_rel_path(row["path"] || row[0])
        next if rel.empty?
        next unless binary_rel_path?(rel)

        name = File.basename(rel)
        abs = File.join(QUARKS_ROOT, rel)
        next unless File.exist?(abs) || File.symlink?(abs)
        next unless (File.executable?(abs) rescue true)

        out[name] ||= abs
      end

      out
    end

    def find_collisions(files, exclude_package: nil)
      rel_files = Array(files).map { |path| normalize_rel_path!(path) }.reject { |path| GeneratedPaths.generated?(path) }.uniq
      return [] if rel_files.empty?

      excluded = exclude_package && normalize_name(exclude_package)
      rel_files.each_slice(500).flat_map do |slice|
        placeholders = (["?"] * slice.length).join(",")
        sql = "SELECT path, package_name FROM files WHERE path IN (#{placeholders})"
        params = slice.dup
        if excluded
          sql << " AND package_name != ?"
          params << excluded
        end
        @db.execute(sql, params).map do |row|
          { path: row["path"] || row[0], owner: (row["package_name"] || row[1]).to_s }
        end
      end
    end

    def cache_dirs
      [CACHE_ROOT, File.join(STATE_ROOT, "var", "tmp", "quarks")].uniq
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

    def package_summaries
      @package_summary_cache ||= @db.execute("SELECT name, version, atom, category FROM packages").each_with_object({}) do |row, summaries|
        name = (row["name"] || row[0]).to_s.downcase
        next if name.empty?
        summaries[name] = {
          name: row["name"],
          version: row["version"],
          atom: row["atom"],
          category: row["category"]
        }.freeze
      end
    end

    def ensure_dirs!
      Security.secure_directory(File.dirname(DB_PATH))
      Security.secure_directory(CACHE_ROOT)
      Security.secure_directory(LOG_ROOT)
    end

    def open_db!
      if File.exist?(DB_PATH) || File.symlink?(DB_PATH)
        stat = File.lstat(DB_PATH)
        raise DatabaseError, "Database path must be a regular file: #{DB_PATH}" unless stat.file? && !stat.symlink?
        raise DatabaseError, "Database path is group/world writable: #{DB_PATH}" if (stat.mode & 0o022).positive?
      end
      @db = SQLite3::Database.new(DB_PATH)
      File.chmod(0o600, DB_PATH)
      @db.results_as_hash = true
    end

    def configure_db!
      @db.busy_timeout = 5_000
      @db.execute("PRAGMA foreign_keys = ON;")
      @db.execute("PRAGMA journal_mode = WAL;")
      @db.execute("PRAGMA synchronous = FULL;")
      @db.execute("PRAGMA temp_store = MEMORY;")
      ["#{DB_PATH}-wal", "#{DB_PATH}-shm"].each do |path|
        File.chmod(0o600, path) if File.exist?(path)
      end
    end

    def migrate!
      create_meta_table!
      current_version = get_schema_version
      if current_version > SCHEMA_VERSION
        raise DatabaseError, "Database schema #{current_version} is newer than supported schema #{SCHEMA_VERSION}"
      end

      migrations.each do |version, migration|
        next if version <= current_version

        transaction do
          migration.call(@db)
          write_schema_version(version)
        end
      end

      create_missing_tables!
      create_missing_indexes!

      write_schema_version(SCHEMA_VERSION)
      @db.execute("PRAGMA user_version = #{SCHEMA_VERSION};")
      true
    end

    def get_schema_version
      @db.get_first_value("SELECT value FROM meta WHERE key='schema_version'").to_i
    end

    MIGRATIONS = {
      1 => -> db {
        db.execute(<<~SQL)
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
      },
      2 => -> db {
        db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS files(
            path TEXT PRIMARY KEY,
            package_name TEXT NOT NULL,
            FOREIGN KEY(package_name) REFERENCES packages(name) ON DELETE CASCADE
          );
        SQL
      },
      3 => -> db {
        db.execute(<<~SQL)
          CREATE TABLE IF NOT EXISTS world(
            atom TEXT PRIMARY KEY
          );
        SQL
      },
      4 => -> db {
        db.execute(<<~SQL)
          CREATE INDEX IF NOT EXISTS idx_files_pkg ON files(package_name);
          CREATE INDEX IF NOT EXISTS idx_files_path ON files(path);
          CREATE INDEX IF NOT EXISTS idx_packages_atom ON packages(atom);
          CREATE INDEX IF NOT EXISTS idx_packages_name ON packages(name);
        SQL
      },
      5 => -> db {
        db.execute("ALTER TABLE files ADD COLUMN sha256 TEXT")
        db.execute("ALTER TABLE files ADD COLUMN size INTEGER")
        db.execute("ALTER TABLE files ADD COLUMN mode INTEGER")
        db.execute("ALTER TABLE files ADD COLUMN kind TEXT")
      },
      6 => -> db {
        GeneratedPaths::EXACT.each { |path| db.execute("DELETE FROM files WHERE path=?", [path]) }
        db.execute("DELETE FROM files WHERE path LIKE 'usr/share/icons/%/icon-theme.cache'")
        db.execute("DELETE FROM files WHERE path LIKE 'usr/local/share/icons/%/icon-theme.cache'")
        db.execute("DROP INDEX IF EXISTS idx_files_path")
        db.execute("DROP INDEX IF EXISTS idx_packages_name")
      }
    }.freeze

    def migrations
      MIGRATIONS
    end

    def create_missing_tables!
      create_meta_table!
      create_packages_table!
      create_files_table!
      create_world_table!
    end

    def create_missing_indexes!
      create_indexes!
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
          sha256 TEXT,
          size INTEGER,
          mode INTEGER,
          kind TEXT,
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
      @db.execute("CREATE INDEX IF NOT EXISTS idx_packages_atom ON packages(atom);")
    end

    def insert_file_manifest!(package_name, manifest)
      return if manifest.empty?

      @db.prepare("INSERT INTO files(path, package_name, sha256, size, mode, kind) VALUES(?, ?, ?, ?, ?, ?)") do |statement|
        manifest.each do |entry|
          result = statement.execute(entry[:path], package_name, entry[:sha256], entry[:size], entry[:mode], entry[:kind])
          result.close if result.respond_to?(:close)
        end
      end
    end

    def write_schema_version(version)
      @db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('schema_version', ?)", [version.to_i.to_s])
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
      clean = Pathname.new(value).cleanpath.to_s
      return "" if clean == "." || clean == ".." || clean.start_with?("../") || clean.include?("\0")
      clean
    end

    def normalize_rel_path!(path)
      clean = normalize_rel_path(path)
      raise ArgumentError, "Invalid package file path: #{path.inspect}" if clean.empty?
      clean
    end

    def normalize_file_entry(entry)
      if entry.is_a?(Hash)
        data = entry.transform_keys(&:to_sym)
        sha256 = data[:sha256]&.to_s
        unless sha256.nil? || sha256.match?(/\A[0-9a-f]{64}\z/)
          raise ArgumentError, "Invalid file SHA-256: #{sha256.inspect}"
        end
        kind = data[:kind]&.to_s
        raise ArgumentError, "Invalid file kind: #{kind.inspect}" unless kind.nil? || %w[file symlink].include?(kind)
        size = data[:size].nil? ? nil : Integer(data[:size], exception: false)
        raise ArgumentError, "Invalid file size: #{data[:size].inspect}" unless size.nil? || size >= 0
        mode = data[:mode].nil? ? nil : Integer(data[:mode], exception: false)
        raise ArgumentError, "Invalid file mode: #{data[:mode].inspect}" unless mode.nil? || mode.between?(0, 0o7777)
        {
          path: normalize_rel_path!(data[:path]),
          sha256: sha256,
          size: size,
          mode: mode,
          kind: kind
        }
      else
        { path: normalize_rel_path!(entry), sha256: nil, size: nil, mode: nil, kind: nil }
      end
    end

    def normalize_lookup_path(path)
      value = path.to_s.strip
      return "" if value.empty?

      expanded = File.expand_path(value)
      root = File.expand_path(QUARKS_ROOT)

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
    rescue JSON::ParserError => e
      raise DatabaseError, "Invalid package metadata JSON: #{e.message}"
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
