# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

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
      when :held, :h then :held
      when :flagged, :f then :flagged
      when :broken, :b then :broken
      when :masked, :m then :masked
      else :normal
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
      FileUtils.mkdir_p(File.dirname(POLICY_FILE))
      data = @policies.transform_values(&:to_h)
      File.write(POLICY_FILE, JSON.pretty_generate(data))
    end

    def load!
      return unless File.exist?(POLICY_FILE)

      data = JSON.parse(File.read(POLICY_FILE))
      @policies = data.transform_values { |h| PackagePolicy.from_h(h) }
    rescue JSON::ParserError
      @policies = {}
    end

    private

    def normalize_name(name)
      name.to_s.strip.downcase
    end
  end

  class BuildConfig
    PROFILES = {
      minimal: {
        jobs: 1,
        verify: false,
        tests: false,
        optimize: false,
        cache: true
      },
      default: {
        jobs: -> { Quarks::Env.jobs },
        verify: true,
        tests: false,
        optimize: true,
        cache: true
      },
      fast: {
        jobs: -> { Quarks::Env.jobs * 2 },
        verify: true,
        tests: true,
        optimize: true,
        cache: true
      },
      extreme: {
        jobs: -> { Quarks::Env.jobs * 4 },
        verify: true,
        tests: true,
        optimize: true,
        cache: false
      }
    }.freeze

    def self.current
      @current_profile ||= :default
    end

    def self.set(profile)
      @current_profile = normalize_profile(profile)
    end

    def self.normalize_profile(profile)
      case profile.to_s.downcase.to_sym
      when :min, :minimal then :minimal
      when :def, :default then :default
      when :fast, :performance then :fast
      when :max, :extreme, :maximum then :extreme
      else :default
      end
    end

    def self.build_jobs
      cfg = PROFILES[current]
      jobs = cfg[:jobs]
      jobs.respond_to?(:call) ? jobs.call : jobs
    end

    def self.verify_sources?
      PROFILES[current][:verify]
    end

    def self.run_tests?
      PROFILES[current][:tests]
    end

    def self.optimize_build?
      PROFILES[current][:optimize]
    end

    def self.use_cache?
      PROFILES[current][:cache]
    end
  end

  class HookManager
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
      FileUtils.mkdir_p(hook_dir)
      path = File.join(hook_dir, "#{name}#{HOOK_EXTENSION}")
      File.write(path, content)
      path
    end

    def self.run_hook(name, args: [])
      path = File.join(hook_dir, "#{name}#{HOOK_EXTENSION}")
      return nil unless File.exist?(path)

      content = File.read(path)
      execute_hook(content, args)
    end

    def self.delete_hook(name)
      path = File.join(hook_dir, "#{name}#{HOOK_EXTENSION}")
      return false unless File.exist?(path)

      File.delete(path)
      true
    end

    def self.execute_hook(content, args)
      script = StringIO.new

      script.puts("#!/usr/bin/env ruby")
      script.puts("# quarks-hook execution")
      script.puts("# Generated at: #{Time.now}")
      script.puts
      script.puts("QUARKS_HOOK_ARGS = #{args.inspect}")
      script.puts
      script.puts(content)

      code = script.string
      eval(code, TOPLEVEL_BINDING, "(hook)", 0)
    end

    def self.import_hook(url)
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)
      return nil unless response.is_a?(Net::HTTPSuccess)

      name = File.basename(uri.path, ".hook")
      name = "imported" if name.empty?

      create_hook(name, response.body)
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
    MODES = {
      full: { description: "Complete sync, download all metadata", cache: false },
      incremental: { description: "Smart sync using ETags", cache: true },
      shallow: { description: "Only changed packages", cache: true },
      mirror: { description: "Download everything, no verification", cache: false }
    }.freeze

    attr_reader :mode, :progress, :start_time

    def initialize(mode: :incremental)
      @mode = normalize_mode(mode)
      @progress = 0
      @start_time = nil
    end

    def normalize_mode(mode)
      case mode.to_s.downcase.to_sym
      when :full, :complete then :full
      when :inc, :incremental then :incremental
      when :shallow, :quick then :shallow
      when :mirror, :raw then :mirror
      else :incremental
      end
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
      @mode == :incremental || @mode == :shallow
    end

    def verify?
      @mode != :mirror
    end

    def full_sync?
      @mode == :full
    end

    def to_s
      @mode.to_s
    end
  end

  class ProfileManager
    PROFILE_DIR = File.join(Quarks::Env.state_root, "var", "db", "quarks", "profiles")
    ACTIVE_PROFILE_FILE = File.join(PROFILE_DIR, "active")

    def initialize
      FileUtils.mkdir_p(PROFILE_DIR)
    end

    def list
      profiles = {}
      Dir.glob(File.join(PROFILE_DIR, "*.json")).each do |file|
        name = File.basename(file, ".json")
        profiles[name] = load(file)
      end
      profiles
    end

    def create(name, config = {})
      profile = {
        name: name,
        created_at: Time.now.iso8601,
        build: config[:build] || :default,
        sync: config[:sync] || :incremental,
        use_flags: config[:use_flags] || [],
        make_conf: config[:make_conf] || {},
        repos: config[:repos] || []
      }

      path = profile_path(name)
      File.write(path, JSON.pretty_generate(profile))
      profile
    end

    def load(name)
      path = profile_path(name)
      return nil unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue JSON::ParserError
      nil
    end

    def activate(name)
      path = profile_path(name)
      return false unless File.exist?(path)

      File.write(ACTIVE_PROFILE_FILE, name)
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

      if profile["use_flags"]
        use_config = USEConfig.new
        profile["use_flags"].each { |f| use_config.add_flag(f) }
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
      File.join(PROFILE_DIR, "#{name}.json")
    end
  end
end
