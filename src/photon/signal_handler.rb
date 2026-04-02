# frozen_string_literal: true

require "fileutils"
require "json"
require "singleton"

module Photon
  class SignalHandler
    include Singleton

    attr_reader :interrupted, :shutdown_requested, :received_signals

    def initialize
      @interrupted = false
      @shutdown_requested = false
      @received_signals = []
      @handlers = {}
      @state_savers = []
    end

    def setup!
      return if @setup

      trap("INT") { handle_signal("INT") }
      trap("TERM") { handle_signal("TERM") }
      trap("HUP") { handle_signal("HUP") }
      trap("QUIT") { handle_signal("QUIT") }

      @setup = true
    end

    def teardown!
      return unless @setup

      Signal.list.keys.each do |sig|
        begin
          trap(sig, "DEFAULT")
        rescue ArgumentError
        end
      end

      @setup = false
    end

    def on_signal(signal_name, &handler)
      @handlers[signal_name.to_s.upcase] ||= []
      @handlers[signal_name.to_s.upcase] << handler
    end

    def register_state_saver(&saver)
      @state_savers << saver
    end

    def handle_signal(sig)
      @received_signals << sig
      @interrupted = true

      case sig
      when "INT"
        @interrupted = true
      when "TERM", "QUIT", "HUP"
        @shutdown_requested = true
      end

      if ENV["PHOTON_DEBUG"]
        warn "[photon] Received signal: #{sig} (#{@received_signals.length} total)"
      end

      save_state!

      (@handlers[sig] || []).each { |h| h.call(sig) }
      (@handlers["ALL"] || []).each { |h| h.call(sig) }
    end

    def save_state!
      return if @state_savers.empty?

      @state_savers.each do |saver|
        begin
          saver.call
        rescue => e
          warn "[photon] State saver failed: #{e.message}" if ENV["PHOTON_DEBUG"]
        end
      end
    end

    def reset!
      @interrupted = false
      @shutdown_requested = false
    end

    def interrupted?
      @interrupted
    end

    def shutdown?
      @shutdown_requested
    end

    def check_and_raise!
      if @interrupted
        raise InterruptedError, "Operation interrupted by signal"
      end
      if @shutdown_requested
        raise ShutdownError, "Shutdown requested"
      end
    end
  end

  class InterruptedError < StandardError; end
  class ShutdownError < StandardError; end

  class BuildStateManager
    STATE_FILE = -> {
      File.join(Photon::Env.state_root, "var", "lib", "photon", "build_state.json")
    }.call

    def initialize
      FileUtils.mkdir_p(File.dirname(STATE_FILE))
    end

    def save_state(state)
      state[:saved_at] = Time.now.iso8601
      state[:pid] = Process.pid
      File.write(STATE_FILE, JSON.pretty_generate(state))
    end

    def load_state
      return nil unless File.exist?(STATE_FILE)

      begin
        data = JSON.parse(File.read(STATE_FILE))
        return nil if stale?(data)
        data
      rescue JSON::ParserError
        nil
      end
    end

    def clear_state
      FileUtils.rm_f(STATE_FILE)
    end

    def state_exists?
      File.exist?(STATE_FILE)
    end

    def stale?(data)
      return true unless data["saved_at"]

      saved_time = Time.parse(data["saved_at"])
      max_age = ENV["PHOTON_STATE_MAX_AGE"].to_i
      max_age = 86400 if max_age.zero?

      (Time.now - saved_time) > max_age
    rescue
      true
    end

    def current_state
      {
        "phase" => SignalHandler.instance.interrupted? ? "interrupted" : "running",
        "interrupted" => SignalHandler.instance.interrupted?,
        "received_signals" => SignalHandler.instance.received_signals
      }
    end

    class BuildState
      attr_accessor :package, :phase, :start_time, :log_file, :dest_dir, :build_dir

      def initialize(attrs = {})
        @package = attrs["package"]
        @phase = attrs["phase"] || "pending"
        @start_time = attrs["start_time"]
        @log_file = attrs["log_file"]
        @dest_dir = attrs["dest_dir"]
        @build_dir = attrs["build_dir"]
      end

      def to_h
        {
          "package" => @package,
          "phase" => @phase,
          "start_time" => @start_time,
          "log_file" => @log_file,
          "dest_dir" => @dest_dir,
          "build_dir" => @build_dir
        }
      end
    end
  end

  class EmergeQueue
    attr_reader :packages, :completed, :failed, :current

    def initialize
      @packages = []
      @completed = []
      @failed = []
      @current = nil
      @queue_state = {}
    end

    def add(package, deps: [])
      node = {
        package: package,
        deps: deps,
        status: :pending,
        attempts: 0,
        added_at: Time.now.to_i
      }
      @packages << node
      @queue_state[package.name.to_s] = node
    end

    def mark_start(package_name)
      node = @queue_state[package_name.to_s]
      return unless node

      node[:status] = :building
      node[:started_at] = Time.now.to_i
      @current = node
    end

    def mark_complete(package_name)
      node = @queue_state[package_name.to_s]
      return unless node

      node[:status] = :completed
      node[:completed_at] = Time.now.to_i
      @completed << node
      @current = nil
    end

    def mark_failed(package_name, error: nil)
      node = @queue_state[package_name.to_s]
      return unless node

      node[:status] = :failed
      node[:failed_at] = Time.now.to_i
      node[:error] = error&.message
      node[:attempts] += 1
      @failed << node
      @current = nil
    end

    def next_pending
      @packages.find { |n| n[:status] == :pending }
    end

    def has_pending?
      @packages.any? { |n| n[:status] == :pending }
    end

    def progress
      total = @packages.length
      done = @completed.length + @failed.length
      building = @packages.count { |n| n[:status] == :building }

      {
        total: total,
        done: done,
        pending: total - done,
        completed: @completed.length,
        failed: @failed.length,
        building: building
      }
    end

    def to_h
      {
        packages: @packages.map { |n| n[:package].to_h },
        completed: @completed.map { |n| n[:package].to_h },
        failed: @failed.map { |n| n[:package].to_h },
        current: @current&.dig(:package)&.to_h,
        progress: progress
      }
    end

    def state_file_path
      File.join(Photon::Env.state_root, "var", "lib", "photon", "emerge_queue.json")
    end

    def save
      FileUtils.mkdir_p(File.dirname(state_file_path))
      File.write(state_file_path, JSON.pretty_generate(to_h))
    end

    def load
      return nil unless File.exist?(state_file_path)

      JSON.parse(File.read(state_file_path))
    rescue
      nil
    end

    def clear
      @packages.clear
      @completed.clear
      @failed.clear
      @current = nil
      @queue_state.clear
      FileUtils.rm_f(state_file_path)
    end
  end
end
