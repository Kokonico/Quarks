# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "json"

$LOAD_PATH.unshift File.expand_path("../src", __dir__)

require "photon/env"
require "photon/package"
require "photon/database"
require "photon/repository"
require "photon/resolver"
require "photon/hash_verifier"
require "photon/web_repo"
require "photon/system_integration"

module Photon
  module TestHelpers
    def with_temp_dir
      Dir.mktmpdir do |dir|
        yield dir
      end
    end

    def with_env(overrides)
      original = ENV.select { |k, _| overrides.key?(k) }
      ENV.update(overrides)
      yield
    ensure
      ENV.update(original)
      (overrides.keys - original.keys).each { |k| ENV.delete(k) }
    end

    def with_fake_home(&block)
      with_temp_dir do |tmpdir|
        Dir.chdir(tmpdir) do
          with_env(
            "HOME" => tmpdir,
            "PHOTON_ROOT" => File.join(tmpdir, ".local", "photon"),
            "PHOTON_STATE_ROOT" => File.join(tmpdir, ".local", "state", "photon")
          ) do
            FileUtils.mkdir_p(File.join(tmpdir, ".local", "photon"))
            FileUtils.mkdir_p(File.join(tmpdir, ".local", "state", "photon"))
            yield tmpdir
          end
        end
      end
    end

    def create_nuclei_file(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end

    def create_sample_package(name: "test-pkg", version: "1.0.0", deps: [])
      Package.new(name).tap do |pkg|
        pkg.version = version
        pkg.description = "Test package"
        pkg.category = "app"
        pkg.license = "MIT"
        pkg.dependencies = deps
        pkg.sources = []
      end
    end
  end

  class PackageTest < Minitest::Test
    include TestHelpers

    def test_package_initialization
      pkg = Package.new("test")
      assert_equal "test", pkg.name
      assert_equal "0.0.0", pkg.version
      assert_equal "app", pkg.category
    end

    def test_package_atom
      pkg = Package.new("hello")
      pkg.category = "app"
      assert_equal "app/hello", pkg.atom
    end

    def test_package_full_name
      pkg = Package.new("hello")
      pkg.version = "2.12.1"
      assert_equal "hello-2.12.1", pkg.full_name
    end

    def test_package_metadata
      pkg = create_sample_package
      metadata = pkg.to_metadata
      assert_equal "test-pkg", metadata[:name]
      assert_equal "1.0.0", metadata[:version]
      assert_equal "MIT", metadata[:license]
    end

    def test_package_validation
      pkg = Package.new("test")
      pkg.version = "1.0"
      pkg.category = "app"

      assert pkg.validate!

      pkg.name = ""
      assert_raises(NucleiSchemaError) { pkg.validate! }
    end

    def test_nuclei_dsl_parsing
      with_temp_dir do |dir|
        nuclei_path = File.join(dir, "hello.nuclei")
        create_nuclei_file(nuclei_path, <<~NUCLEI)
          nuclei "hello", "2.12.1" do
            description "GNU Hello World"
            homepage "https://www.gnu.org/software/hello/"
            license "GPL-3.0"
            category "app-misc"
            
            depends "sys-libs/ncurses"
            
            source "https://ftp.gnu.org/gnu/hello/hello-2.12.1.tar.gz",
                   sha256: "abc123..."
          end
        NUCLEI

        pkg = Package.load_from_nuclei(nuclei_path)
        assert_equal "hello", pkg.name
        assert_equal "2.12.1", pkg.version
        assert_equal "GNU Hello World", pkg.description
        assert_equal ["sys-libs/ncurses"], pkg.dependencies
      end
    end
  end

  class HashVerifierTest < Minitest::Test
    def test_sha256_verification
      with_temp_dir do |dir|
        test_file = File.join(dir, "test.txt")
        content = "Hello, World!"
        File.write(test_file, content)

        expected_hash = Digest::SHA256.hexdigest(content)

        assert HashVerifier.verify_file(test_file, algorithm: "sha256", expected_hex: expected_hash)
      end
    end

    def test_sha256_verification_failure
      with_temp_dir do |dir|
        test_file = File.join(dir, "test.txt")
        File.write(test_file, "Hello, World!")

        wrong_hash = "0" * 64
        assert_raises(HashVerifier::VerificationError) do
          HashVerifier.verify_file(test_file, algorithm: "sha256", expected_hex: wrong_hash)
        end
      end
    end

    def test_secure_compare
      a = "abcd1234"
      b = "abcd1234"
      c = "ABCD1234"

      assert HashVerifier.secure_compare_hex(a, b)
      refute HashVerifier.secure_compare_hex(a, c)
    end

    def test_supported_algorithms
      assert HashVerifier.supported?("sha256")
      assert HashVerifier.supported?("sha512")
      assert HashVerifier.supported?("sha1")
      assert HashVerifier.supported?("md5")
      refute HashVerifier.supported?("blake2")
    end
  end

  class DatabaseTest < Minitest::Test
    include TestHelpers

    def setup
      @tmpdir = Dir.mktmpdir
      ENV["PHOTON_ROOT"] = File.join(@tmpdir, "photon")
      ENV["PHOTON_STATE_ROOT"] = File.join(@tmpdir, "state", "photon")
      FileUtils.mkdir_p(File.join(@tmpdir, "state", "photon", "var", "db"))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_database_initialization
      db = Database.new
      assert db.ready?
      assert db.list_packages.empty?
    end

    def test_add_package
      db = Database.new
      pkg = create_sample_package

      files = ["bin/hello", "share/doc/hello/README"]
      result = db.add_package(pkg, files: files)
      assert result

      assert db.installed?("test-pkg")
      refute db.installed?("nonexistent")
    end

    def test_remove_package
      db = Database.new
      pkg = create_sample_package

      db.add_package(pkg, files: ["bin/test"])
      assert db.installed?("test-pkg")

      db.remove_package("test-pkg")
      refute db.installed?("test-pkg")
    end

    def test_world_list
      db = Database.new
      pkg = create_sample_package

      db.add_package(pkg, files: ["bin/test"])
      db.world_add(pkg.atom)

      assert_includes db.world_list, pkg.atom
    end

    def test_normalize_name
      db = Database.new
      assert_equal "hello", db.normalize_name("hello")
      assert_equal "hello", db.normalize_name("app/hello")
      assert_equal "hello", db.normalize_name("APP/HELLO")
    end

    def test_file_ownership
      db = Database.new
      pkg = create_sample_package
      db.add_package(pkg, files: ["bin/test", "lib/libtest.so"])

      owner = db.owner_of("bin/test")
      assert_equal "test-pkg", owner[:name]

      owner = db.owner_of("/nonexistent/path")
      assert_nil owner
    end

    def test_which_command
      db = Database.new
      pkg = create_sample_package
      db.add_package(pkg, files: ["bin/hello", "usr/bin/world"])

      result = db.which_command("hello")
      assert_equal "test-pkg", result[:name]

      result = db.which_command("world")
      assert_equal "test-pkg", result[:name]
    end

    def test_collision_detection
      db = Database.new
      pkg1 = create_sample_package(name: "pkg1")
      db.add_package(pkg1, files: ["bin/shared"])

      pkg2 = create_sample_package(name: "pkg2")
      collisions = db.find_collisions(["bin/shared"], exclude_package: "pkg1")
      assert_empty collisions

      collisions = db.find_collisions(["bin/shared"], exclude_package: "nonexistent")
      assert_equal 1, collisions.length
      assert_equal "pkg1", collisions[0][:owner]
    end

    def test_package_retrieval
      db = Database.new
      pkg = create_sample_package
      db.add_package(pkg, files: ["bin/test", "etc/config"])

      info = db.get_package("test-pkg")
      assert_equal "test-pkg", info[:name]
      assert_equal "1.0.0", info[:version]
      assert_equal 2, info[:files].length
    end
  end

  class ResolverTest < Minitest::Test
    include TestHelpers

    def setup
      @tmpdir = Dir.mktmpdir
      @repo_dir = File.join(@tmpdir, "nuclei")
      @state_dir = File.join(@tmpdir, "state", "photon")
      FileUtils.mkdir_p(@repo_dir)
      FileUtils.mkdir_p(@state_dir)

      ENV["PHOTON_ROOT"] = File.join(@tmpdir, "photon")
      ENV["PHOTON_STATE_ROOT"] = @state_dir
      ENV["PHOTON_NUCLEI_PATHS"] = @repo_dir
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def create_test_package(name, version, deps: [])
      pkg_dir = File.join(@repo_dir, "app")
      FileUtils.mkdir_p(pkg_dir)
      nuclei_path = File.join(pkg_dir, "#{name}.nuclei")

      deps_str = deps.map { |d| %(depends "#{d}") }.join("\n")

      File.write(nuclei_path, <<~NUCLEI)
        nuclei "#{name}", "#{version}" do
          description "Test package"
          category "app"
          #{deps_str}
        end
      NUCLEI
    end

    def test_simple_resolution
      create_test_package("hello", "1.0")
      db = Database.new
      repo = Repository.new

      resolver = DependencyResolver.new(repo, db)
      packages = resolver.resolve("hello")

      assert_equal 1, packages.length
      assert_equal "hello", packages[0].name
    end

    def test_dependency_resolution
      create_test_package("base", "1.0")
      create_test_package("app", "1.0", deps: ["base"])

      db = Database.new
      repo = Repository.new

      resolver = DependencyResolver.new(repo, db)
      packages = resolver.resolve("app")

      assert_equal 2, packages.length
      assert_equal "base", packages[0].name
      assert_equal "app", packages[1].name
    end

    def test_circular_dependency_detection
      pkg_dir = File.join(@repo_dir, "app")
      FileUtils.mkdir_p(pkg_dir)
      File.write(File.join(pkg_dir, "a.nuclei"), <<~NUCLEI)
        nuclei "a", "1.0" do
          description "Package A"
          category "app"
          depends "b"
        end
      NUCLEI

      File.write(File.join(pkg_dir, "b.nuclei"), <<~NUCLEI)
        nuclei "b", "1.0" do
          description "Package B"
          category "app"
          depends "a"
        end
      NUCLEI

      db = Database.new
      repo = Repository.new

      resolver = DependencyResolver.new(repo, db)
      assert_raises(RuntimeError) { resolver.resolve("a") }
    end

    def test_skip_already_installed
      create_test_package("installed", "1.0")

      db = Database.new
      pkg = Package.new("installed")
      db.add_package(pkg, files: ["bin/installed"])

      repo = Repository.new
      resolver = DependencyResolver.new(repo, db)
      packages = resolver.resolve("installed")

      assert_empty packages
    end
  end

  class SystemIntegrationTest < Minitest::Test
    include TestHelpers

    def test_library_detection
      with_temp_dir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib"))
        FileUtils.touch(File.join(dir, "lib", "libtest.so"))
        FileUtils.touch(File.join(dir, "lib", "libtest.a"))

        pkg = create_sample_package
        integrator = SystemIntegration.new(pkg, dir)
        actions = SystemIntegration.install_handlers(pkg, dir, dir)

        ldconfig_action = actions.find { |a| a[:type] == :ldconfig }
        refute_nil ldconfig_action
      end
    end

    def test_desktop_file_detection
      with_temp_dir do |dir|
        desktop_dir = File.join(dir, "usr", "share", "applications")
        FileUtils.mkdir_p(desktop_dir)

        File.write(File.join(desktop_dir, "test.desktop"), <<~DESKTOP)
          [Desktop Entry]
          Name=Test
          Exec=test
        DESKTOP

        pkg = create_sample_package
        actions = SystemIntegration.install_handlers(pkg, dir, dir)

        desktop_action = actions.find { |a| a[:type] == :desktop_file }
        refute_nil desktop_action
      end
    end

    def test_man_page_categorization
      with_temp_dir do |dir|
        man_dir = File.join(dir, "usr", "share", "man", "man1")
        FileUtils.mkdir_p(man_dir)
        FileUtils.touch(File.join(man_dir, "test.1"))

        pkg = create_sample_package
        integrator = SystemIntegration.new(pkg, dir)
        actions = SystemIntegration.install_handlers(pkg, dir, dir)

        man_action = actions.find { |a| a[:type] == :man_pages }
        refute_nil man_action
        assert_equal "man1", man_action[:section]
      end
    end
  end

  class WebRepoManagerTest < Minitest::Test
    include TestHelpers

    def test_repository_metadata
      meta = WebRepoManager::RepositoryMetadata.new(
        name: "test-repo",
        repo_url: "https://example.com/repo",
        priority: 100
      )

      assert_equal "test-repo", meta.name
      assert_equal 100, meta.priority
      assert meta.enabled
      refute meta.expired?
    end

    def test_metadata_serialization
      meta = WebRepoManager::RepositoryMetadata.new(
        name: "test-repo",
        repo_url: "https://example.com/repo",
        priority: 50,
        gpg_key_id: "ABC123"
      )

      h = meta.to_h
      assert_equal "test-repo", h[:name]
      assert_equal 50, h[:priority]
      assert_equal "ABC123", h[:gpg_key_id]

      restored = WebRepoManager::RepositoryMetadata.from_h(h)
      assert_equal meta.name, restored.name
      assert_equal meta.priority, restored.priority
    end

    def test_expired_detection
      meta = WebRepoManager::RepositoryMetadata.new(
        name: "test",
        repo_url: "https://example.com"
      )

      refute meta.expired?

      meta.last_sync = Time.now - (WebRepoManager::OFFLINE_GRACE_PERIOD + 100)
      assert meta.expired?
    end
  end

  class ConflictResolverTest < Minitest::Test
    include TestHelpers

    def setup
      @tmpdir = Dir.mktmpdir
      ENV["PHOTON_ROOT"] = File.join(@tmpdir, "photon")
      ENV["PHOTON_STATE_ROOT"] = File.join(@tmpdir, "state", "photon")
      FileUtils.mkdir_p(File.join(@tmpdir, "state", "photon", "var", "db"))
    end

    def teardown
      FileUtils.rm_rf(@tmpdir)
    end

    def test_blocking_conflict_detection
      db = Database.new
      repo = Repository.new
      resolver = ConflictResolver.new(repo, db)

      pkg = Package.new("ncurses")
      pkg.category = "sys-libs"

      conflicts = resolver.check_blocking_conflicts(pkg)
      refute_empty conflicts
      assert_equal :blocking, conflicts[0][:type]
    end

    def test_no_conflicts_for_normal_package
      db = Database.new
      repo = Repository.new
      resolver = ConflictResolver.new(repo, db)

      pkg = Package.new("hello")
      pkg.category = "app-misc"

      conflicts = resolver.check_blocking_conflicts(pkg)
      assert_empty conflicts
    end
  end
end
