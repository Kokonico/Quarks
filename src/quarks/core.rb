# frozen_string_literal: true

require "fileutils"
require "json"
require "time"
require "digest"
require "net/http"
require "openssl"
require "rbconfig"
require "tempfile"
require "timeout"
require "quarks/env"
require "quarks/security"

module Quarks
  class PackagePolicy
    attr_reader :package, :policy, :since, :reason, :metadata

    def initialize(package:, policy:, since: Time.now, reason: nil, metadata: {})
      @package = package
      @policy = normalize_policy(policy)
      @since = since
      @reason = reason
      @metadata = metadata
    end

    def normalize_policy(policy)
      case policy.to_s.downcase.to_sym
      when :normal, :n then :normal
      when :held, :h then :held
      when :flagged, :f then :flagged
      when :broken, :b then :broken
      when :masked, :m then :masked
      else raise ArgumentError, "Unknown package policy: #{policy.inspect}"
      end
    end

    def held?
      @policy == :held
    end

    def flagged?
      @policy == :flagged
    end

    def broken?
      @policy == :broken
    end

    def masked?
      @policy == :masked
    end

    def normal?
      @policy == :normal
    end

    def to_h
      {
        package: @package,
        policy: @policy.to_s,
        since: @since.iso8601,
        reason: @reason,
        metadata: @metadata
      }
    end

    def self.from_h(h)
      raise ArgumentError, "Policy entry must contain an object" unless h.is_a?(Hash)
      new(
        package: h["package"],
        policy: h["policy"],
        since: Time.parse(h["since"]),
        reason: h["reason"],
        metadata: h["metadata"] || {}
      )
    end
  end

  class PolicyManager
    POLICY_FILE = File.join(Quarks::Env.state_root, "var", "db", "quarks", "policies.json")

    def initialize
      @policies = {}
      load!
    end

    def set_policy(package_name, policy, reason: nil, metadata: {})
      normalized = normalize_name(package_name)
      @policies[normalized] = PackagePolicy.new(
        package: normalized,
        policy: policy,
        reason: reason,
        metadata: metadata
      )
      save!
    end

    def get_policy(package_name)
      normalized = normalize_name(package_name)
      @policies[normalized]
    end

    def hold(package_name, reason: nil)
      set_policy(package_name, :held, reason: reason)
    end

    def release(package_name)
      set_policy(package_name, :normal)
    end

    def flag(package_name, reason: nil)
      set_policy(package_name, :flagged, reason: reason)
    end

    def unflag(package_name)
      set_policy(package_name, :normal)
    end

    def mask(package_name, reason: nil)
      set_policy(package_name, :masked, reason: reason)
    end

    def unmask(package_name)
      set_policy(package_name, :normal)
    end

    def is_held?(package_name)
      policy = get_policy(package_name)
      policy&.held?
    end

    def is_flagged?(package_name)
      policy = get_policy(package_name)
      policy&.flagged?
    end

    def is_masked?(package_name)
      policy = get_policy(package_name)
      policy&.masked?
    end

    def list_held
      @policies.select { |_, p| p.held? }.values
    end

    def list_flagged
      @policies.select { |_, p| p.flagged? }.values
    end

    def list_masked
      @policies.select { |_, p| p.masked? }.values
    end

    def list_by_policy(policy)
      normalized = PackagePolicy.new(package: nil, policy: policy).policy
      @policies.select { |_, p| p.policy == normalized }.values
    end

    def clear_policy(package_name)
      normalized = normalize_name(package_name)
      @policies.delete(normalized)
      save!
    end

    def save!
      data = @policies.transform_values(&:to_h)
      Quarks::Security.atomic_write(POLICY_FILE, JSON.pretty_generate(data))
    end

    def load!
      return unless File.exist?(POLICY_FILE)

      data = JSON.parse(File.read(POLICY_FILE))
      raise ArgumentError, "Policy database must contain an object" unless data.is_a?(Hash)
      @policies = data.transform_values { |h| PackagePolicy.from_h(h) }
    rescue JSON::ParserError, ArgumentError => e
      raise ArgumentError, "Invalid policy database #{POLICY_FILE}: #{e.message}"
    end

    private

    def normalize_name(name)
      value = name.to_s.strip.downcase
      unless value.match?(/\A(?:[a-z0-9][a-z0-9+_.-]*\/)?[a-z0-9][a-z0-9+_.-]*\z/)
        raise ArgumentError, "Invalid package policy name: #{name.inspect}"
      end
      value.split("/", 2).last
    end
  end

  class BuildConfig
    CONFIG_FILE = File.join(Quarks::Env.state_root, "var", "db", "quarks", "build_profile")
    PROFILES = {
      minimal: { jobs: 1 },
      default: { jobs: -> { Quarks::Env.jobs } },
      fast: { jobs: -> { Quarks::Env.jobs * 2 } },
      extreme: { jobs: -> { Quarks::Env.jobs * 4 } }
    }.freeze

    def self.current
      return @current_profile if @current_profile
      return @current_profile = :default unless File.file?(CONFIG_FILE)
      stored = File.read(CONFIG_FILE).strip
      @current_profile = normalize_profile(stored)
      raise ArgumentError, "Invalid stored build profile: #{stored.inspect}" unless @current_profile
      @current_profile
    end

    def self.set(profile)
      normalized = normalize_profile(profile)
      raise ArgumentError, "Unknown build profile: #{profile}" unless normalized
      @current_profile = normalized
      Quarks::Security.atomic_write(CONFIG_FILE, normalized.to_s)
      normalized
    end

    def self.normalize_profile(profile)
      case profile.to_s.downcase.to_sym
      when :min, :minimal then :minimal
      when :def, :default then :default
      when :fast, :performance then :fast
      when :max, :extreme, :maximum then :extreme
      else nil
      end
    end

    def self.build_jobs
      cfg = PROFILES[current]
      jobs = cfg[:jobs]
      jobs.respond_to?(:call) ? jobs.call : jobs
    end

  end

  class HookManager
    SAFE_NAME = /\A[a-zA-Z0-9*][a-zA-Z0-9*_.-]*\z/.freeze
    HOOK_DIR = File.join(Quarks::Env.xdg_config_home, "quarks", "hooks")
    HOOK_EXTENSION = ".hook"

    def self.hook_dir
      FileUtils.mkdir_p(HOOK_DIR)
      HOOK_DIR
    end

    def self.list_hooks
      Dir.glob(File.join(hook_dir, "*#{HOOK_EXTENSION}")).map do |path|
        {
          name: File.basename(path, HOOK_EXTENSION),
          path: path,
          size: File.size(path),
          modified: File.mtime(path)
        }
      end
    end

    def self.create_hook(name, content)
      validate_name!(name)
      raise ArgumentError, "Hook exceeds 1 MiB" if content.to_s.bytesize > 1024 * 1024
      path = File.join(hook_dir, "#{name}#{HOOK_EXTENSION}")
      Quarks::Security.atomic_write(path, content.to_s)
      path
    end

    def self.run_hook(name, args: [])
      validate_name!(name)
      path = File.join(hook_dir, "#{name}#{HOOK_EXTENSION}")
      return nil unless File.exist?(path)

      content = File.read(path)
      execute_hook(content, args)
    end

    def self.delete_hook(name)
      validate_name!(name)
      path = File.join(hook_dir, "#{name}#{HOOK_EXTENSION}")
      return false unless File.exist?(path)

      File.delete(path)
      true
    end

    def self.execute_hook(content, args)
      script = Tempfile.new(["quarks-hook-", ".rb"])
      output_file = Tempfile.new(["quarks-hook-stdout-", ".log"])
      error_file = Tempfile.new(["quarks-hook-stderr-", ".log"])
      script.write("# frozen_string_literal: true\nrequire 'json'\nQUARKS_HOOK_ARGS = JSON.parse(ENV.fetch('QUARKS_HOOK_ARGS'))\n")
      script.write(content.to_s)
      script.flush

      environment = {
        "QUARKS_HOOK_ARGS" => JSON.generate(args),
        "PATH" => ENV.fetch("PATH", "/usr/bin:/bin"),
        "LANG" => ENV.fetch("LANG", "C.UTF-8"),
        "LC_ALL" => ENV.fetch("LC_ALL", "C.UTF-8")
      }
      pid = Process.spawn(
        environment,
        RbConfig.ruby,
        script.path,
        in: File::NULL,
        out: output_file.path,
        err: error_file.path,
        unsetenv_others: true,
        pgroup: true,
        rlimit_cpu: 60,
        rlimit_fsize: 1024 * 1024,
        rlimit_nofile: 64
      )
      _, status = Timeout.timeout(60) { Process.wait2(pid) }
      output = File.binread(output_file.path, 1024 * 1024)
      error_output = File.binread(error_file.path, 1024 * 1024)
      raise "Hook failed (exit #{status.exitstatus}): #{error_output.strip}" unless status.success?
      output
    rescue Timeout::Error
      Process.kill("KILL", -pid) rescue nil
      Process.wait(pid) rescue nil
      raise "Hook timed out after 60 seconds"
    ensure
      script&.close!
      output_file&.close!
      error_file&.close!
    end

    def self.import_hook(url, sha256: nil)
      raise ArgumentError, "A SHA-256 digest is required when importing a hook" unless sha256.to_s.match?(/\A[0-9a-fA-F]{64}\z/)
      uri = Security.validate_remote_uri!(url, purpose: "hook import")
      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = Security.resolve_public_addresses!(uri.host, purpose: "hook import").first
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 10
      http.read_timeout = 30
      http.max_retries = 0
      response = nil
      body = +"".b
      http.request(Net::HTTP::Get.new(uri)) do |incoming|
        response = incoming
        next unless incoming.is_a?(Net::HTTPSuccess)

        declared = Integer(incoming["Content-Length"], exception: false)
        raise "Imported hook exceeds 1 MiB" if declared && declared > 1024 * 1024
        incoming.read_body do |chunk|
          raise "Imported hook exceeds 1 MiB" if body.bytesize + chunk.bytesize > 1024 * 1024
          body << chunk
        end
      end
      return nil unless response.is_a?(Net::HTTPSuccess)
      actual = Digest::SHA256.hexdigest(body)
      raise "Hook checksum mismatch" unless actual == sha256.downcase

      name = File.basename(uri.path, ".hook")
      name = "imported" if name.empty?

      create_hook(name, body)
    end

    def self.validate_name!(name)
      value = name.to_s
      raise ArgumentError, "Invalid hook name: #{value.inspect}" unless value.match?(SAFE_NAME)
      value
    end

    def self.run_hooks_for(event, context = {})
      hooks = list_hooks.select { |h| hook_matches_event?(h[:name], event) }
      hooks.each do |hook|
        begin
          run_hook(hook[:name], args: [event, context])
        rescue => e
          warn "[quarks] Hook #{hook[:name]} failed: #{e.message}"
        end
      end
    end

    def self.hook_matches_event?(name, event)
      name.start_with?("#{event}.") || name == event || name == "*"
    end
  end

  class SyncMode
    CONFIG_FILE = File.join(Quarks::Env.state_root, "var", "db", "quarks", "sync_mode")
    MODES = {
      full: { description: "Force a fresh, verified metadata download", cache: false },
      incremental: { description: "Use verified caches and conditional requests", cache: true }
    }.freeze

    attr_reader :mode, :progress, :start_time

    def initialize(mode: self.class.current)
      @mode = normalize_mode(mode)
      @progress = 0
      @start_time = nil
    end

    def normalize_mode(mode)
      case mode.to_s.downcase.to_sym
      when :full, :complete then :full
      when :inc, :incremental then :incremental
      else
        raise ArgumentError, "Unknown sync mode: #{mode}"
      end
    end

    def self.current
      return :incremental unless File.file?(CONFIG_FILE)
      new(mode: File.read(CONFIG_FILE).strip).mode
    end

    def self.set(mode)
      normalized = new(mode: mode).mode
      Quarks::Security.atomic_write(CONFIG_FILE, normalized.to_s)
      normalized
    end

    def start
      @start_time = Time.now
      @progress = 0
    end

    def update(progress)
      @progress = progress.clamp(0, 100)
    end

    def finish
      @progress = 100
    end

    def duration
      return 0 unless @start_time
      Time.now - @start_time
    end

    def cache_only?
      @mode == :incremental
    end

    def verify?
      true
    end

    def full_sync?
      @mode == :full
    end

    def to_s
      @mode.to_s
    end
  end

  class ProfileManager
    SAFE_NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/.freeze
    PROFILE_DIR = File.join(Quarks::Env.state_root, "var", "db", "quarks", "profiles")
    ACTIVE_PROFILE_FILE = File.join(PROFILE_DIR, "active")

    def initialize
      FileUtils.mkdir_p(PROFILE_DIR)
    end

    def list
      profiles = {}
      Dir.glob(File.join(PROFILE_DIR, "*.json")).each do |file|
        name = File.basename(file, ".json")
        profiles[name] = load(name)
      end
      profiles
    end

    def create(name, config = {})
      current_use = USEConfig.new.flags
      profile = {
        name: name,
        created_at: Time.now.iso8601,
        build: config.fetch(:build, BuildConfig.current),
        sync: config.fetch(:sync, SyncMode.current),
        use_flags: config.fetch(:use_flags, current_use),
        make_conf: config[:make_conf] || {},
        repos: config[:repos] || []
      }

      path = profile_path(name)
      Quarks::Security.atomic_write(path, JSON.pretty_generate(profile))
      profile
    end

    def load(name)
      path = profile_path(name)
      return nil unless File.exist?(path)

      profile = JSON.parse(File.read(path))
      raise ArgumentError, "Profile must contain an object" unless profile.is_a?(Hash)
      profile
    rescue JSON::ParserError => e
      raise ArgumentError, "Invalid profile #{name}: #{e.message}"
    end

    def activate(name)
      path = profile_path(name)
      return false unless File.exist?(path)

      Quarks::Security.atomic_write(ACTIVE_PROFILE_FILE, name.to_s)
      apply(name)
      true
    end

    def active
      return nil unless File.exist?(ACTIVE_PROFILE_FILE)

      name = File.read(ACTIVE_PROFILE_FILE).strip
      load(name)
    end

    def apply(name)
      profile = load(name)
      return unless profile

      if profile["build"]
        BuildConfig.set(profile["build"].to_sym)
      end

      SyncMode.set(profile["sync"]) if profile["sync"]

      if profile["use_flags"]
        use_config = USEConfig.new
        use_config.replace_global_flags(profile["use_flags"])
        use_config.save!
      end
    end

    def delete(name)
      path = profile_path(name)
      return false unless File.exist?(path)

      File.delete(path)
      true
    end

    private

    def profile_path(name)
      raise ArgumentError, "Invalid profile name: #{name.inspect}" unless name.to_s.match?(SAFE_NAME)
      File.join(PROFILE_DIR, "#{name}.json")
    end
  end
end
