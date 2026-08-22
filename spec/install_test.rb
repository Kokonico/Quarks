# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require_relative "../install"

class QuarksBootstrapTest < Minitest::Test
  def test_parses_unattended_distribution_options
    options = QuarksBootstrap::CLI.parse(%w[
      --mode distribution --destdir /tmp/quarks-pkg --prefix /usr/lib/quarks
      --bindir /usr/bin --no-dependencies --yes --dry-run --no-color
    ])

    assert_equal "distribution", options.mode
    assert_equal "/tmp/quarks-pkg", options.destdir
    assert_equal "/usr/lib/quarks", options.prefix
    assert_equal "/usr/bin", options.bindir
    assert_equal false, options.dependencies
    assert options.yes
    assert options.dry_run
  end

  def test_distribution_dry_run_does_not_create_destdir
    destination = File.join(Dir.tmpdir, "quarks-installer-test-#{Process.pid}")
    FileUtils.rm_rf(destination)
    options = QuarksBootstrap::Options.new(
      mode: "distribution", destdir: destination, yes: true, dry_run: true,
      color: false
    )
    output = StringIO.new
    ui = QuarksBootstrap::UI.new(input: StringIO.new, output: output, color: false)
    runner = QuarksBootstrap::Runner.new(ui, dry_run: true)

    assert QuarksBootstrap::Installer.new(options, ui: ui, runner: runner).run
    refute Dir.exist?(destination)
    assert_includes output.string, "Profile          distribution"
    assert_includes output.string, "dry run"
  ensure
    FileUtils.rm_rf(destination) if destination
  end

  def test_rejects_root_as_destdir
    options = QuarksBootstrap::Options.new(
      mode: "distribution", destdir: "/", yes: true, dry_run: true,
      color: false
    )
    output = StringIO.new
    ui = QuarksBootstrap::UI.new(input: StringIO.new, output: output, color: false)
    runner = QuarksBootstrap::Runner.new(ui, dry_run: true)

    error = assert_raises(QuarksBootstrap::Error) do
      QuarksBootstrap::Installer.new(options, ui: ui, runner: runner).run
    end
    assert_includes error.message, "unsafe destdir"
  end
end
