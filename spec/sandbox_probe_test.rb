# frozen_string_literal: true

require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../src", __dir__)
require "quarks/sandbox_build"

class SandboxProbeTest < Minitest::Test
  Status = Struct.new(:success?, :exitstatus)

  def test_probe_mounts_etc_before_running_alternatives_backed_executable
    skip "bubblewrap is not installed" unless Quarks::SandboxManager.available?
    captured = nil
    replacement = lambda do |_environment, *argv, **_options|
      captured = argv
      ["", Status.new(true, 0)]
    end

    Quarks::SandboxManager.instance_variable_set(:@probe_results, {})
    original_capture2e = Open3.method(:capture2e)
    Open3.define_singleton_method(:capture2e, replacement)
    begin
      assert Quarks::SandboxManager.operational?
    ensure
      Open3.define_singleton_method(:capture2e) do |*argv, **options, &block|
        original_capture2e.call(*argv, **options, &block)
      end
      Quarks::SandboxManager.instance_variable_set(:@probe_results, {})
    end

    refute_nil captured
    assert_includes captured.each_cons(3).to_a, ["--ro-bind", "/etc", "/etc"]
    assert_equal "/bin/true", captured.last
  end
end
