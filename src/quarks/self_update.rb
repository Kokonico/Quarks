# frozen_string_literal: true

require "json"
require "digest"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require "time"
require "uri"
require "quarks/env"
require "quarks/security"

module Quarks
  module SelfUpdate
    extend self

    CHECK_TTL = 86_400
    MAX_FILE_BYTES = 65_536
    VALID_REF = %r{\Arefs/heads/[A-Za-z0-9][A-Za-z0-9._/-]*\z}
    GIT_PATHS = %w[/usr/bin/git /bin/git].freeze
    GIT_ENV = {
      "PATH" => "/usr/bin:/bin",
      "LANG" => "C",
      "LC_ALL" => "C",
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => "/dev/null",
      "GIT_TERMINAL_PROMPT" => "0",
      "GCM_INTERACTIVE" => "never",
      "GIT_ASKPASS" => "/bin/false",
      "SSH_ASKPASS" => "/bin/false"
    }.freeze
    GIT_OPTIONS = [
      "-c", "protocol.file.allow=never",
      "-c", "protocol.ext.allow=never",
      "-c", "http.sslVerify=true",
      "-c", "http.followRedirects=false",
      "-c", "core.hooksPath=/dev/null",
      "-c", "credential.helper="
    ].freeze

    class Error < StandardError; end

    def check_if_due(force: false)
      return { status: :disabled } if !force && ENV["QUARKS_SELF_UPDATE_CHECK"] == "0"
      receipt = load_receipt
      return { status: :unsupported, reason: receipt.dig("source", "reason") } unless managed_receipt?(receipt)

      cached = load_cache
      ttl = Integer(ENV.fetch("QUARKS_SELF_UPDATE_TTL", CHECK_TTL.to_s), exception: false) || CHECK_TTL
      if !force && cache_fresh?(cached, receipt, ttl)
        return symbolize_status(cached)
      end

      remote = remote_commit(receipt)
      status = remote == receipt.dig("source", "commit") ? "up_to_date" : "available"
      data = {
        "schema_version" => 1,
        "checked_at" => Time.now.utc.iso8601,
        "status" => status,
        "installed_commit" => receipt.dig("source", "commit"),
        "remote_commit" => remote,
        "url" => receipt.dig("source", "url"),
        "tracking_ref" => receipt.dig("source", "tracking_ref")
      }
      write_cache(data)
      symbolize_status(data)
    rescue => e
      { status: :error, error: e.message }
    end

    def install!(remote_commit: nil, dry_run: false)
      receipt = load_receipt
      raise Error, unsupported_message(receipt) unless managed_receipt?(receipt)
      remote_commit ||= remote_commit(receipt)
      current = receipt.dig("source", "commit")
      return { status: :up_to_date, commit: current } if remote_commit == current

      Dir.mktmpdir("quarks-self-update-") do |directory|
        checkout = File.join(directory, "source")
        branch = receipt.dig("source", "branch")
        run_git!("clone", "--no-tags", "--single-branch", "--branch", branch, "--", receipt.dig("source", "url"), checkout)
        candidate = run_git!("-C", checkout, "rev-parse", "HEAD").strip
        raise Error, "Upstream changed during update check; run self-update again" unless candidate == remote_commit
        run_git!("-C", checkout, "merge-base", "--is-ancestor", current, candidate)
        verify_candidate_signature!(checkout, candidate, receipt.fetch("source"))
        return { status: :available, commit: candidate } if dry_run

        install = File.join(checkout, "install.rb")
        raise Error, "Verified checkout does not contain install.rb" unless File.file?(install)
        args = installer_arguments(receipt)
        success = system(
          { "PATH" => "/usr/bin:/bin", "HOME" => ENV.fetch("HOME", Dir.home) },
          RbConfig.ruby, install, *args,
          unsetenv_others: true
        )
        raise Error, "Quarks installer failed; the existing installation was preserved or rolled back" unless success
        { status: :updated, commit: candidate }
      end
    end

    def receipt_available?
      managed_receipt?(load_receipt)
    rescue
      false
    end

    private

    def receipt_path
      path = ENV["QUARKS_INSTALL_RECEIPT"].to_s
      raise Error, "This Quarks installation has no bootstrap receipt" if path.empty?
      File.expand_path(path)
    end

    def load_receipt
      path = receipt_path
      raise Error, "Install receipt must be a regular file" unless File.file?(path) && !File.symlink?(path)
      raise Error, "Install receipt is too large" if File.size(path) > MAX_FILE_BYTES
      stat = File.stat(path)
      raise Error, "Install receipt is group/world writable" if (stat.mode & 0o022).positive?
      receipt = JSON.parse(File.read(path))
      raise Error, "Unsupported install receipt schema" unless receipt["schema_version"] == 1
      installation = receipt["installation"]
      raise Error, "Install receipt has invalid installation metadata" unless installation.is_a?(Hash)
      expected_owner = installation["mode"] == "managed" ? 0 : Process.euid
      raise Error, "Install receipt has an unexpected owner" unless stat.uid == expected_owner
      launcher = File.expand_path(installation.fetch("launcher"))
      prefix = File.expand_path(installation.fetch("prefix"))
      raise Error, "Install receipt paths must be absolute" unless Pathname.new(installation["launcher"]).absolute? && Pathname.new(installation["prefix"]).absolute?
      raise Error, "Install receipt does not belong to this launcher" unless File.expand_path($PROGRAM_NAME) == launcher
      raise Error, "Installed launcher is missing or unsafe" unless File.file?(launcher) && !File.symlink?(launcher)
      checksum = Digest::SHA256.file(launcher).hexdigest
      raise Error, "Installed launcher does not match its receipt" unless checksum == receipt.dig("installed", "launcher_sha256")
      if installation["mode"] != "distribution" && File.expand_path(installation["installed_prefix"].to_s) != prefix
        raise Error, "Install prefix is inconsistent"
      end
      receipt
    rescue JSON::ParserError => e
      raise Error, "Install receipt is corrupt: #{e.message}"
    end

    def managed_receipt?(receipt)
      source = receipt["source"]
      return false unless source.is_a?(Hash) && source["managed"] == true
      return false unless source["commit"].to_s.match?(/\A[0-9a-f]{40,64}\z/)
      return false unless source["signing_fingerprint"].to_s.match?(/\A[0-9A-F]{40,64}\z/)
      return false unless source["signing_key"].is_a?(String) && source["signing_key"].bytesize.between?(1, 48 * 1024)
      return false unless source["tracking_ref"].to_s.match?(VALID_REF)
      return false unless source["branch"].to_s == source["tracking_ref"].delete_prefix("refs/heads/")
      valid_https_url?(source["url"])
    end

    def valid_https_url?(value)
      uri = Security.validate_remote_uri!(value, purpose: "Quarks update upstream", resolve: false)
      uri.scheme == "https" && uri.userinfo.nil? && uri.fragment.nil?
    rescue URI::InvalidURIError, SecurityViolation, SocketError
      false
    end

    def git_path
      GIT_PATHS.find { |path| File.file?(path) && File.executable?(path) } || raise(Error, "git is required for repository updates")
    end

    def remote_commit(receipt)
      source = receipt.fetch("source")
      Security.validate_remote_uri!(source.fetch("url"), purpose: "Quarks update upstream", resolve: true)
      output = run_git!("ls-remote", "--refs", "--exit-code", "--", source.fetch("url"), source.fetch("tracking_ref"))
      lines = output.lines.map(&:strip).reject(&:empty?)
      raise Error, "Upstream returned an ambiguous tracking reference" unless lines.length == 1
      commit, ref = lines.first.split(/\s+/, 2)
      unless ref == source["tracking_ref"] && commit&.match?(/\A[0-9a-f]{40,64}\z/)
        raise Error, "Upstream returned an invalid tracking reference"
      end
      commit
    end

    def run_git!(*args)
      output, error, status = Open3.capture3(GIT_ENV, git_path, *GIT_OPTIONS, *args, unsetenv_others: true)
      raise Error, "git output exceeded safety limit" if output.bytesize > MAX_FILE_BYTES || error.bytesize > MAX_FILE_BYTES
      raise Error, "git #{args.first} failed: #{error.lines.first.to_s.strip}" unless status.success?
      output
    end

    def verify_candidate_signature!(checkout, candidate, source)
      gpg = %w[/usr/bin/gpg /bin/gpg /usr/bin/gpg2].find { |path| File.file?(path) && File.executable?(path) }
      raise Error, "GnuPG is required to authenticate Quarks updates" unless gpg
      Dir.mktmpdir("quarks-update-keyring-") do |home|
        File.chmod(0o700, home)
        _output, error, status = Open3.capture3(
          { "PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C" },
          gpg, "--batch", "--homedir", home, "--import",
          stdin_data: source.fetch("signing_key"), unsetenv_others: true
        )
        raise Error, "Could not import the pinned Quarks signing key: #{error.lines.first.to_s.strip}" unless status.success?
        env = GIT_ENV.merge("GNUPGHOME" => home)
        output, verify_error, verify_status = Open3.capture3(
          env, git_path, *GIT_OPTIONS, "-c", "gpg.program=#{gpg}",
          "-C", checkout, "verify-commit", "--raw", candidate,
          unsetenv_others: true
        )
        raise Error, "Candidate commit does not have a valid signature" unless verify_status.success?
        match = "#{output}\n#{verify_error}".match(/^\[GNUPG:\] VALIDSIG ([0-9A-F]{40,64})\b/)
        unless match && match[1] == source.fetch("signing_fingerprint")
          raise Error, "Candidate commit was signed by an unexpected key"
        end
      end
      true
    end

    def installer_arguments(receipt)
      installation = receipt.fetch("installation")
      args = [
        "--mode", installation.fetch("mode"),
        "--prefix", installation.fetch("prefix"),
        "--bindir", installation.fetch("bindir"),
        "--yes", "--no-color"
      ]
      args += ["--user", installation.fetch("user"), "--home", installation.fetch("home")] if installation["mode"] == "managed"
      args << (installation["dependencies"] ? "--dependencies" : "--no-dependencies")
      args
    end

    def cache_path
      File.join(Env.state_root, "var", "cache", "quarks", "self-update.json")
    end

    def load_cache
      return nil unless File.file?(cache_path) && !File.symlink?(cache_path)
      return nil if File.size(cache_path) > MAX_FILE_BYTES
      JSON.parse(File.read(cache_path))
    rescue JSON::ParserError
      nil
    end

    def cache_fresh?(cache, receipt, ttl)
      return false unless cache.is_a?(Hash) && cache["schema_version"] == 1
      return false unless cache["installed_commit"] == receipt.dig("source", "commit")
      return false unless cache["url"] == receipt.dig("source", "url")
      checked = Time.iso8601(cache["checked_at"].to_s)
      now = Time.now
      checked <= now + 300 && now - checked < ttl
    rescue ArgumentError
      false
    end

    def write_cache(data)
      Security.secure_directory(File.dirname(cache_path))
      Security.atomic_write(cache_path, JSON.generate(data) + "\n", mode: 0o600)
    end

    def symbolize_status(data)
      {
        status: data.fetch("status").to_sym,
        installed_commit: data["installed_commit"],
        remote_commit: data["remote_commit"]
      }
    end

    def unsupported_message(receipt)
      reason = receipt.dig("source", "reason") || "missing verified repository provenance"
      "This installation cannot self-update (#{reason}); reinstall from a clean HTTPS Git checkout"
    end
  end
end
