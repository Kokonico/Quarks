require "minitest/autorun"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require "quarks/package"
require "quarks/smart_resolver"

class ResolverFastPathTest < Minitest::Test
  class Repo
    def initialize(packages)
      @packages = packages.to_h { |package| [package.name.downcase, package] }
      @blockers = {}
      packages.each do |package|
        Array(package.blocks).each do |blocked|
          target = normalize_name(blocked)
          (@blockers[target] ||= []) << package.atom.downcase
        end
      end
    end

    def find_package(value)
      @packages[normalize_name(value)]
    end

    def normalize_name(value)
      value.to_s.downcase.split("/", 2).last.to_s
    end

    def blockers_for(value)
      Array(@blockers[normalize_name(value)])
    end
  end

  class Database
    attr_reader :full_reads

    def initialize(installed = {})
      @installed = installed.transform_keys { |key| key.to_s.downcase }
      @full_reads = 0
    end

    def installed?(value)
      @installed.key?(value.to_s.downcase.split("/", 2).last)
    end

    def package_summary(value)
      @installed[value.to_s.downcase.split("/", 2).last]&.dup
    end

    def get_package(_value)
      @full_reads += 1
      raise "resolver requested a full package manifest"
    end
  end

  class UseConfig
    def flags_for_package(_package)
      []
    end
  end

  def test_installed_dependency_version_check_uses_summary_only
    dependency = package("dep", "1.0")
    target = package("vim", "9.0")
    target.dependencies = ["app/dep"]
    database = Database.new("dep" => { name: "dep", atom: "app/dep", version: "1.0", category: "app" })
    resolver = Quarks::SmartResolver.new(Repo.new([target, dependency]), database, use_config: UseConfig.new)

    result = resolver.resolve_all(["vim"])
    assert_equal ["app/vim"], result.map(&:atom)
    assert_equal 0, database.full_reads
  end

  def test_selected_packages_cannot_bypass_blockers_by_request_order
    blocked = package("blocked", "1.0")
    blocker = package("blocker", "1.0")
    blocker.blocks = ["app/blocked"]
    resolver = Quarks::SmartResolver.new(Repo.new([blocked, blocker]), Database.new, use_config: UseConfig.new)

    assert_raises(Quarks::SmartResolver::BlockedPackageError) do
      resolver.resolve_all(["blocked", "blocker"])
    end
  end

  private

  def package(name, version)
    Quarks::Package.new(name).tap do |package|
      package.category = "app"
      package.version = version
    end
  end
end
