require "minitest/autorun"
require "tmpdir"
require "fileutils"

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require "quarks/installer"

class UninstallSafetyTest < Minitest::Test
  def test_registered_path_rejects_symlink_parent
    Dir.mktmpdir("quarks-root-") do |root|
      Dir.mktmpdir("quarks-outside-") do |outside|
        File.symlink(outside, File.join(root, "usr"))
        installer = Quarks::Installer.allocate

        assert_raises(Quarks::Installer::InstallError) do
          installer.send(:validate_registered_paths!, ["usr/bin/vim"], root)
        end
      end
    end
  end

  def test_registered_path_cannot_escape_install_root
    Dir.mktmpdir("quarks-root-") do |root|
      installer = Quarks::Installer.allocate

      assert_raises(Quarks::Installer::InstallError) do
        installer.send(:validate_registered_paths!, ["../outside"], root)
      end
    end
  end
end
