require "minitest/autorun"
require "set"
require "stringio"

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require "quarks"

class RemovePlannerTest < Minitest::Test
  class Database
    def initialize(packages)
      @packages = packages
    end

    def normalize_name(value)
      value.to_s.strip.downcase.split("/", 2).last.to_s
    end

    def list_package_metadata
      @packages.map(&:dup)
    end
  end

  def test_categorized_dependency_blocks_removal
    cli = build_cli([
      package("vim", "app-editors/vim"),
      package("plugin", "app/plugin", dependencies: ["app-editors/vim"])
    ])

    error = capture_io do
      assert_raises(SystemExit) { cli.send(:remove_packages, ["vim"]) }
    end.first
    assert_includes error, "Cannot remove app-editors/vim"
    assert_includes error, "app/plugin"
  end

  def test_remove_planner_does_not_require_removed_find_dependents_helper
    cli = build_cli([package("vim", "app-editors/vim")])

    output = capture_io { cli.send(:remove_packages, ["vim"]) }.first
    assert_includes output, "app-editors/vim-9.0"
    assert_includes output, "Pretend run"
  end

  def test_selected_dependents_are_removed_before_dependencies
    cli = build_cli([])
    dependencies = {
      "library" => [],
      "editor" => ["library"],
      "plugin" => ["editor"]
    }

    assert_equal %w[plugin editor library], cli.send(:removal_order, %w[library plugin editor], dependencies)
  end

  def test_selected_dependent_does_not_block_joint_removal
    cli = build_cli([
      package("vim", "app-editors/vim"),
      package("plugin", "app/plugin", dependencies: ["app-editors/vim"])
    ])

    output = capture_io { cli.send(:remove_packages, ["vim", "plugin"]) }.first
    plugin_position = output.index("app/plugin-9.0")
    vim_position = output.index("app-editors/vim-9.0")
    refute_nil plugin_position
    refute_nil vim_position
    assert_operator plugin_position, :<, vim_position
  end

  def test_depclean_does_not_require_repository_service
    database = Database.new([
      package("leaf", "app/leaf")
    ])
    def database.world_list = []
    cli = Quarks::CLI.allocate
    cli.instance_variable_set(:@database, database)
    cli.instance_variable_set(:@repository, nil)
    cli.instance_variable_set(:@options, { pretend: true, ask: false })

    output = capture_io { cli.send(:depclean_packages) }.first
    assert_includes output, "app/leaf"
  end

  private

  def build_cli(packages)
    Quarks::CLI.allocate.tap do |cli|
      cli.instance_variable_set(:@database, Database.new(packages))
      cli.instance_variable_set(:@options, { force: false, pretend: true, ask: false })
    end
  end

  def package(name, atom, dependencies: [], build_dependencies: [])
    {
      name: name,
      version: "9.0",
      atom: atom,
      category: atom.split("/", 2).first,
      metadata: {
        dependencies: dependencies,
        build_dependencies: build_dependencies
      }
    }
  end
end
