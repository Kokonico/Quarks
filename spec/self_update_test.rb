# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

$LOAD_PATH.unshift File.expand_path("../src", __dir__)
require "quarks/config"
require "quarks/self_update"

class SelfUpdateTest < Minitest::Test
  def test_unmanaged_receipt_does_not_run_git
    Dir.mktmpdir("quarks-self-update-") do |root|
      receipt = File.join(root, "receipt.json")
      launcher = File.expand_path($PROGRAM_NAME)
      File.write(receipt, JSON.generate(
        "schema_version" => 1,
        "installation" => { "mode" => "personal", "prefix" => root, "installed_prefix" => root, "launcher" => launcher },
        "installed" => { "launcher_sha256" => Digest::SHA256.file(launcher).hexdigest },
        "source" => { "managed" => false, "reason" => "dirty_checkout" }
      ))
      previous = ENV["QUARKS_INSTALL_RECEIPT"]
      ENV["QUARKS_INSTALL_RECEIPT"] = receipt
      result = Quarks::SelfUpdate.check_if_due(force: true)
      assert_equal :unsupported, result[:status]
      assert_equal "dirty_checkout", result[:reason]
    ensure
      previous.nil? ? ENV.delete("QUARKS_INSTALL_RECEIPT") : ENV["QUARKS_INSTALL_RECEIPT"] = previous
    end
  end

  def test_config_accepts_update_check_settings
    config = Quarks::Config.parse("self_update_check = false\nself_update_ttl = 3600\n")
    assert_equal false, config["self_update_check"]
    assert_equal 3600, config["self_update_ttl"]
  end
end
