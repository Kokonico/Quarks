# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "tmpdir"

QUARKS_MIGRATION_WORKSPACE = Dir.mktmpdir("quarks-database-migration-")
ENV["QUARKS_ROOT"] = File.join(QUARKS_MIGRATION_WORKSPACE, "root")
ENV["QUARKS_STATE_ROOT"] = File.join(QUARKS_MIGRATION_WORKSPACE, "state")

Minitest.after_run { FileUtils.rm_rf(QUARKS_MIGRATION_WORKSPACE) }

$LOAD_PATH.unshift File.expand_path("../src", __dir__)
require "quarks/database"

class DatabaseMigrationTest < Minitest::Test
  def test_schema_four_with_manifest_columns_migrates
    [Quarks::Database::DB_PATH, "#{Quarks::Database::DB_PATH}-wal", "#{Quarks::Database::DB_PATH}-shm"].each { |path| FileUtils.rm_f(path) }
    FileUtils.mkdir_p(File.dirname(Quarks::Database::DB_PATH))
    legacy = SQLite3::Database.new(Quarks::Database::DB_PATH)
    legacy.execute("CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
    legacy.execute("INSERT INTO meta(key, value) VALUES('schema_version', '4')")
    legacy.execute("CREATE TABLE packages(name TEXT PRIMARY KEY, version TEXT NOT NULL, atom TEXT, category TEXT, installed_at INTEGER, install_time REAL, metadata_json TEXT)")
    legacy.execute("CREATE TABLE files(path TEXT PRIMARY KEY, package_name TEXT NOT NULL, sha256 TEXT, size INTEGER, mode INTEGER, kind TEXT)")
    legacy.execute("CREATE TABLE world(atom TEXT PRIMARY KEY)")
    legacy.execute("INSERT INTO packages(name, version, atom, category) VALUES('legacy', '1', 'app/legacy', 'app')")
    legacy.execute("INSERT INTO files(path, package_name, sha256) VALUES('usr/bin/legacy', 'legacy', '#{"a" * 64}')")
    legacy.close

    database = Quarks::Database.new
    assert_equal "a" * 64, database.get_package("legacy")[:file_manifest].first[:sha256]
    assert_equal Quarks::Database::SCHEMA_VERSION, database.stats[:user_version]
  ensure
    database&.close
  end
end
