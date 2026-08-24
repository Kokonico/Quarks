# frozen_string_literal: true

require "minitest/autorun"
require "digest"
require "json"
require "stringio"
require_relative "../install"

class QuarksBootstrapTest < Minitest::Test
  def bootstrap_options(root, action: "install")
    QuarksBootstrap::Options.new(
      mode: "personal", prefix: File.join(root, "prefix"), bindir: File.join(root, "bin"),
      home: root, dependencies: true, action: action, yes: true, color: false
    )
  end

  def bootstrap_installer(options)
    ui = QuarksBootstrap::UI.new(input: StringIO.new, output: StringIO.new, color: false)
    QuarksBootstrap::Installer.new(options, ui: ui, runner: QuarksBootstrap::Runner.new(ui))
  end

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

  def test_parses_uninstall_and_purge_actions
    assert_equal "purge", QuarksBootstrap::CLI.parse(%w[--mode personal --uninstall]).action
    assert_equal "purge", QuarksBootstrap::CLI.parse(%w[--mode personal --purge]).action
    assert_equal "uninstall", QuarksBootstrap::CLI.parse(%w[--mode personal --remove-program-only]).action
    assert_raises(QuarksBootstrap::Error) do
      QuarksBootstrap::CLI.parse(%w[--mode personal --uninstall --remove-program-only])
    end
  end

  def test_commit_failure_restores_prefix_launcher_and_receipt
    Dir.mktmpdir("quarks-bootstrap-rollback-") do |root|
      options = bootstrap_options(root)
      installer = bootstrap_installer(options)
      prefix = options.prefix
      launcher = File.join(options.bindir, "quarks")
      receipt = File.join(root, ".prefix-install.json")
      FileUtils.mkdir_p(prefix)
      FileUtils.mkdir_p(options.bindir)
      File.write(File.join(prefix, "old"), "old")
      File.write(launcher, "old launcher")
      File.write(receipt, "old receipt")
      stage_prefix = File.join(root, ".prefix.stage-#{Process.pid}-#{"a" * 12}")
      stage_launcher = File.join(options.bindir, ".quarks.stage-#{Process.pid}-#{"b" * 12}")
      FileUtils.mkdir(stage_prefix)
      File.write(File.join(stage_prefix, "new"), "new")
      File.write(stage_launcher, "new launcher")
      installer.define_singleton_method(:write_receipt!) { |*| raise QuarksBootstrap::Error, "injected receipt failure" }

      assert_raises(QuarksBootstrap::Error) do
        installer.send(:commit_install!, stage_prefix, stage_launcher, "2.0.0")
      end
      assert_equal "old", File.read(File.join(prefix, "old"))
      assert_equal "old launcher", File.read(launcher)
      assert_equal "old receipt", File.read(receipt)
      refute File.exist?(File.join(root, ".prefix-transaction.json"))
    end
  end

  def test_clean_replacement_keeps_backup_and_removes_stale_payload
    Dir.mktmpdir("quarks-bootstrap-replace-") do |root|
      options = bootstrap_options(root)
      installer = bootstrap_installer(options)
      prefix = options.prefix
      launcher = File.join(options.bindir, "quarks")
      FileUtils.mkdir_p(prefix)
      FileUtils.mkdir_p(options.bindir)
      File.write(File.join(prefix, "stale"), "old")
      File.write(launcher, "old launcher")
      stage_prefix = File.join(root, ".prefix.stage-#{Process.pid}-#{"c" * 12}")
      stage_launcher = File.join(options.bindir, ".quarks.stage-#{Process.pid}-#{"d" * 12}")
      FileUtils.mkdir(stage_prefix)
      File.write(File.join(stage_prefix, "current"), "new")
      File.write(stage_launcher, "new launcher")
      installer.define_singleton_method(:write_receipt!) { |*| File.write(send(:receipt_path), "receipt") }
      installer.define_singleton_method(:verify_committed_install!) { |_| true }

      installer.send(:commit_install!, stage_prefix, stage_launcher, "2.0.0")
      refute File.exist?(File.join(prefix, "stale"))
      assert_equal "new", File.read(File.join(prefix, "current"))
      backups = Dir[File.join(root, ".prefix-backups", "prefix-*")]
      assert_equal 1, backups.length
      assert_equal "old", File.read(File.join(backups.first, "stale"))
    end
  end

  def test_interrupted_transaction_restores_atomic_prefix_backup
    Dir.mktmpdir("quarks-bootstrap-recovery-") do |root|
      options = bootstrap_options(root)
      installer = bootstrap_installer(options)
      prefix = options.prefix
      launcher = File.join(options.bindir, "quarks")
      backup_root = File.join(root, ".prefix-backups")
      backup_prefix = File.join(backup_root, "prefix-20260823120000-deadbeef")
      stage_prefix = File.join(root, ".prefix.stage-#{Process.pid}-#{"e" * 12}")
      stage_launcher = File.join(options.bindir, ".quarks.stage-#{Process.pid}-#{"f" * 12}")
      backup_launcher = File.join(options.bindir, ".quarks.backup-#{Process.pid}-#{"a" * 12}")
      receipt = File.join(root, ".prefix-install.json")
      backup_receipt = File.join(root, "..prefix-install.json.backup-#{Process.pid}-#{"b" * 12}")
      FileUtils.mkdir_p(prefix)
      FileUtils.mkdir_p(backup_prefix)
      FileUtils.mkdir_p(options.bindir)
      File.write(File.join(prefix, "new"), "new")
      File.write(File.join(backup_prefix, "old"), "old")
      journal = {
        "schema_version" => 1, "live_prefix" => prefix, "launcher" => launcher, "receipt" => receipt,
        "stage_prefix" => stage_prefix, "stage_launcher" => stage_launcher,
        "backup_prefix" => backup_prefix, "backup_launcher" => backup_launcher, "backup_receipt" => backup_receipt,
        "had_prefix" => true, "had_launcher" => false, "had_receipt" => false,
        "prefix_backed_up" => true, "prefix_published" => true,
        "launcher_backed_up" => false, "launcher_published" => false,
        "receipt_backed_up" => false, "receipt_published" => false
      }
      File.write(File.join(root, ".prefix-transaction.json"), JSON.generate(journal))

      installer.send(:recover_interrupted_transaction!)
      assert_equal "old", File.read(File.join(prefix, "old"))
      refute File.exist?(File.join(prefix, "new"))
      refute File.exist?(File.join(root, ".prefix-transaction.json"))
    end
  end

  def test_purge_removes_only_quarks_roots_and_path_snippet
    Dir.mktmpdir("quarks-bootstrap-purge-") do |root|
      options = bootstrap_options(root, action: "purge")
      installer = bootstrap_installer(options)
      launcher = File.join(options.bindir, "quarks")
      state = File.join(root, ".local", "state", "quarks")
      package_root = File.join(root, ".local", "quarks")
      config = File.join(root, ".config", "quarks")
      FileUtils.mkdir_p(options.prefix)
      FileUtils.mkdir_p(options.bindir)
      FileUtils.mkdir_p(state)
      FileUtils.mkdir_p(package_root)
      FileUtils.mkdir_p(config)
      File.write(launcher, "#!/bin/sh\n# Generated by the Quarks bootstrap installer.\n")
      receipt = {
        "schema_version" => 1,
        "installation" => {
          "mode" => "personal", "prefix" => options.prefix, "installed_prefix" => options.prefix,
          "bindir" => options.bindir, "launcher" => launcher, "user" => nil, "home" => root,
          "data_roots" => [package_root, state, config]
        },
        "installed" => { "launcher_sha256" => Digest::SHA256.file(launcher).hexdigest }
      }
      File.write(File.join(root, ".prefix-install.json"), JSON.generate(receipt))
      File.write(File.join(root, ".zshrc"), "before\n# >>> quarks setup-path >>>\nexport PATH=x\n# <<< quarks setup-path <<<\nafter\n")
      File.write(File.join(root, "keep"), "safe")

      previous_root = ENV["QUARKS_ROOT"]
      previous_state = ENV["QUARKS_STATE_ROOT"]
      previous_config = ENV["XDG_CONFIG_HOME"]
      ENV["QUARKS_ROOT"] = package_root
      ENV["QUARKS_STATE_ROOT"] = state
      ENV["XDG_CONFIG_HOME"] = File.join(root, ".config")
      installer.send(:uninstall!, purge: true)
      refute File.exist?(options.prefix)
      refute File.exist?(state)
      refute File.exist?(package_root)
      refute File.exist?(config)
      assert_equal "before\nafter\n", File.read(File.join(root, ".zshrc"))
      assert_equal "safe", File.read(File.join(root, "keep"))
    ensure
      previous_root.nil? ? ENV.delete("QUARKS_ROOT") : ENV["QUARKS_ROOT"] = previous_root
      previous_state.nil? ? ENV.delete("QUARKS_STATE_ROOT") : ENV["QUARKS_STATE_ROOT"] = previous_state
      previous_config.nil? ? ENV.delete("XDG_CONFIG_HOME") : ENV["XDG_CONFIG_HOME"] = previous_config
    end
  end

  def test_recursive_removal_rejects_symlinked_ancestor
    Dir.mktmpdir("quarks-bootstrap-symlink-") do |root|
      outside = Dir.mktmpdir("quarks-bootstrap-outside-")
      File.symlink(outside, File.join(root, "linked"))
      options = bootstrap_options(root)
      options.prefix = File.join(root, "linked", "prefix")
      installer = bootstrap_installer(options)
      FileUtils.mkdir_p(File.join(outside, "prefix"))

      assert_raises(QuarksBootstrap::Error) do
        installer.send(:remove_tree!, options.prefix)
      end
      assert Dir.exist?(File.join(outside, "prefix"))
    ensure
      FileUtils.rm_rf(outside) if outside
    end
  end

  def test_receipt_identity_mismatch_prevents_destructive_action
    Dir.mktmpdir("quarks-bootstrap-receipt-") do |root|
      options = bootstrap_options(root)
      installer = bootstrap_installer(options)
      receipt = {
        "schema_version" => 1,
        "installation" => {
          "mode" => "personal", "prefix" => options.prefix, "installed_prefix" => options.prefix,
          "bindir" => options.bindir, "launcher" => File.join(options.bindir, "quarks"),
          "user" => nil, "home" => File.join(root, "different-home")
        }
      }
      assert_raises(QuarksBootstrap::Error) { installer.send(:validate_receipt!, receipt) }
    end
  end
end
