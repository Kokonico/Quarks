# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"

class EnvironmentCliTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def run_quarks(*arguments)
    Open3.capture3(RbConfig.ruby, File.join(ROOT, "quarks"), *arguments)
  end

  def test_main_help_links_environment_reference_without_dumping_it
    output, error, status = run_quarks("help")
    assert status.success?, error
    assert_includes output, "environment"
    refute_includes output, "QUARKS_ROOT"
    refute_includes output, "ENVIRONMENT\n"
  end

  def test_environment_command_groups_variables_and_examples
    output, error, status = run_quarks("environment")
    assert status.success?, error
    assert_includes output, "Quarks Environment Reference"
    assert_includes output, "Paths and configuration"
    assert_includes output, "Repository security"
    assert_includes output, "QUARKS_ROOT"
    assert_includes output, "QUARKS_JOBS=8 quarks install vim"
    assert_includes output, "quarks env"
  end

  def test_env_help_is_an_alias
    output, error, status = run_quarks("env-help")
    assert status.success?, error
    assert_includes output, "Quarks Environment Reference"
  end
end
