# frozen_string_literal: true

require "fileutils"
require "open3"
require "quarks/security"

module Quarks
  class SystemdManager
    UNIT_NAME_PATTERN = /\A[a-zA-Z0-9@_.:-]+\z/.freeze
    SERVICE_TEMPLATE = <<~TEMPLATE
      [Unit]
      Description=%{description}
      After=network.target
      Wants=network.target

      [Service]
      Type=%{service_type}
      ExecStart=%{exec_start}
      %{exec_stop}
      %{exec_reload}
      Restart=%{restart}
      RestartSec=%{restart_sec}
      User=%{user}
      Group=%{group}
      %{environment}
      StandardOutput=%{stdout}
      StandardError=%{stderr}

      %{security}

      [Install]
      WantedBy=multi-user.target
    TEMPLATE

    TIMER_TEMPLATE = <<~TEMPLATE
      [Unit]
      Description=%{description}
      Requires=%{service}

      [Timer]
      OnCalendar=%{on_calendar}
      Persistent=%{persistent}
      RandomizedDelaySec=%{randomized_delay}

      [Install]
      WantedBy=timers.target
    TEMPLATE

    DEFAULT_OPTIONS = {
      service_type: "simple",
      restart: "on-failure",
      restart_sec: 5,
      user: "root",
      group: "root",
      stdout: "journal",
      stderr: "journal",
      persistent: "yes",
      randomized_delay: 60
    }.freeze

    def self.generate_service_file(name, options = {})
      validate_unit_name!(name)
      opts = DEFAULT_OPTIONS.merge(options)

      description = single_line!(opts[:description] || "#{name} service", "description")
      exec_start = single_line!(opts[:exec_start], "ExecStart", required: true)
      exec_stop = opts[:exec_stop] ? "ExecStop=#{single_line!(opts[:exec_stop], 'ExecStop')}" : ""
      exec_reload = opts[:exec_reload] ? "ExecReload=#{single_line!(opts[:exec_reload], 'ExecReload')}" : ""

      env_vars = opts[:environment]
      env_block = if env_vars.is_a?(Hash) && env_vars.any?
        env_vars.map { |k, v| environment_line(k, v) }.join("\n")
      elsif env_vars.is_a?(Array)
        env_vars.map do |entry|
          key, value = entry.to_s.split("=", 2)
          environment_line(key, value)
        end.join("\n")
      elsif env_vars
        key, value = env_vars.to_s.split("=", 2)
        environment_line(key, value)
      else
        ""
      end

      security = generate_security_options(opts)

      service_content = SERVICE_TEMPLATE % {
        description: description,
        service_type: enum!(opts[:service_type], %w[simple exec forking oneshot dbus notify notify-reload idle], "service type"),
        exec_start: exec_start,
        exec_stop: exec_stop,
        exec_reload: exec_reload,
        restart: enum!(opts[:restart], %w[no on-success on-failure on-abnormal on-watchdog on-abort always], "restart policy"),
        restart_sec: nonnegative_number!(opts[:restart_sec], "RestartSec"),
        user: single_line!(opts[:user], "User", required: true),
        group: single_line!(opts[:group], "Group", required: true),
        environment: env_block,
        stdout: single_line!(opts[:stdout], "StandardOutput", required: true),
        stderr: single_line!(opts[:stderr], "StandardError", required: true),
        security: security
      }.transform_values { |v| v.to_s }

      service_content
    end

    def self.generate_timer_file(name, options = {})
      validate_unit_name!(name)
      opts = DEFAULT_OPTIONS.merge(options)

      description = single_line!(opts[:timer_description] || "#{name} timer", "timer description", required: true)
      service = validate_unit_name!(opts[:service] || "#{name}.service")
      on_calendar = single_line!(opts[:on_calendar] || "daily", "OnCalendar", required: true)
      persistent = opts[:persistent] ? "yes" : "no"
      randomized_delay = nonnegative_number!(opts[:randomized_delay] || 60, "RandomizedDelaySec")

      timer_content = TIMER_TEMPLATE % {
        description: description,
        service: service,
        on_calendar: on_calendar,
        persistent: persistent,
        randomized_delay: randomized_delay
      }

      timer_content
    end

    def self.install_service(name, dest_dir, options = {})
      service_name = options[:service_name] || name
      validate_unit_name!(service_name)
      install_root = dest_dir || Database::QUARKS_ROOT

      service_dir = File.join(install_root, "usr", "lib", "systemd", "system")
      FileUtils.mkdir_p(service_dir)

      service_file = File.join(service_dir, "#{service_name}.service")
      Quarks::Security.atomic_write(service_file, generate_service_file(service_name, options), mode: 0o644)

      if options[:timer]
        timer_file = File.join(service_dir, "#{service_name}.timer")
        Quarks::Security.atomic_write(timer_file, generate_timer_file(service_name, options), mode: 0o644)
      end

      {
        service: service_file,
        timer: options[:timer] ? File.join(service_dir, "#{service_name}.timer") : nil
      }
    end

    def self.uninstall_service(name, dest_dir)
      validate_unit_name!(name)
      install_root = dest_dir || Database::QUARKS_ROOT

      service_dir = File.join(install_root, "usr", "lib", "systemd", "system")
      service_file = File.join(service_dir, "#{name}.service")
      timer_file = File.join(service_dir, "#{name}.timer")

      removed = []
      if File.exist?(service_file)
        File.delete(service_file)
        removed << service_file
      end

      if File.exist?(timer_file)
        File.delete(timer_file)
        removed << timer_file
      end

      removed
    end

    def self.enable_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would enable service: #{name}"
        return true
      end

      systemctl("enable", name)
    end

    def self.disable_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would disable service: #{name}"
        return true
      end

      systemctl("disable", name)
    end

    def self.start_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would start service: #{name}"
        return true
      end

      systemctl("start", name)
    end

    def self.stop_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would stop service: #{name}"
        return true
      end

      systemctl("stop", name)
    end

    def self.restart_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would restart service: #{name}"
        return true
      end

      systemctl("restart", name)
    end

    def self.service_status(name)
      validate_unit_name!(name)
      executable = trusted_systemctl
      return { output: "systemctl not available", running: false } unless executable
      output, status = Open3.capture2e(
        restricted_environment,
        executable, "status", normalized_unit_name(name),
        unsetenv_others: true
      )
      { output: output, running: status.success? }
    rescue
      { output: "systemctl not available", running: false }
    end

    private

    def self.systemctl(action, name)
      validate_unit_name!(name)
      executable = trusted_systemctl
      return false unless executable
      command = [executable, action, normalized_unit_name(name)]
      if !Process.euid.zero?
        sudo = trusted_sudo
        return false unless sudo
        command.unshift(sudo)
      end
      system(
        restricted_environment,
        *command,
        out: File::NULL, err: File::NULL, unsetenv_others: true
      )
    end

    def self.trusted_systemctl
      %w[/usr/bin/systemctl /bin/systemctl].find { |path| File.file?(path) && File.executable?(path) }
    end

    def self.trusted_sudo
      %w[/usr/bin/sudo /bin/sudo].find { |path| File.file?(path) && File.executable?(path) }
    end

    def self.restricted_environment
      { "PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C" }
    end

    def self.normalized_unit_name(name)
      value = name.to_s
      value.include?(".") ? value : "#{value}.service"
    end

    def self.validate_unit_name!(name)
      value = name.to_s
      raise ArgumentError, "Invalid systemd unit name: #{value.inspect}" unless value.match?(UNIT_NAME_PATTERN)
      value
    end

    def self.single_line!(value, field, required: false)
      text = value.to_s
      raise ArgumentError, "#{field} is required" if required && text.empty?
      raise ArgumentError, "Invalid #{field}: newline or NUL is not allowed" if text.include?("\0") || text.match?(/[\r\n]/)
      text
    end

    def self.enum!(value, allowed, field)
      text = single_line!(value, field, required: true)
      raise ArgumentError, "Invalid #{field}: #{text.inspect}" unless allowed.include?(text)
      text
    end

    def self.nonnegative_number!(value, field)
      text = value.to_s
      raise ArgumentError, "Invalid #{field}: #{value.inspect}" unless text.match?(/\A\d+(?:\.\d+)?(?:ms|s|min|h|d)?\z/)
      text
    end

    def self.environment_line(key, value)
      name = key.to_s
      raise ArgumentError, "Invalid environment variable: #{name.inspect}" unless name.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
      escaped = single_line!(value, "environment value").gsub("\\", "\\\\").gsub('"', '\\"')
      "Environment=\"#{name}=#{escaped}\""
    end

    def self.generate_security_options(opts)
      return "" unless opts[:security]

      security_opts = opts[:security]
      lines = []

      if security_opts[:no_new_privileges]
        lines << "NoNewPrivileges=yes"
      end

      if security_opts[:protect_system]
        lines << "ProtectSystem=#{enum!(security_opts[:protect_system], %w[yes no full strict], 'ProtectSystem')}"
      end

      if security_opts[:private_tmp]
        lines << "PrivateTmp=yes"
      end

      if security_opts[:read_only_paths]
        paths = Array(security_opts[:read_only_paths]).map { |path| single_line!(path, "ReadOnlyPaths") }.join(" ")
        lines << "ReadOnlyPaths=#{paths}"
      end

      if security_opts[:read_write_paths]
        paths = Array(security_opts[:read_write_paths]).map { |path| single_line!(path, "ReadWritePaths") }.join(" ")
        lines << "ReadWritePaths=#{paths}"
      end

      if security_opts[:capabilities]
        lines << "CapabilityBoundingSet=#{single_line!(security_opts[:capabilities], 'CapabilityBoundingSet')}"
      end

      if security_opts[:memory_limit]
        lines << "MemoryLimit=#{single_line!(security_opts[:memory_limit], 'MemoryLimit')}"
      end

      if security_opts[:cpu_quota]
        lines << "CPUQuota=#{single_line!(security_opts[:cpu_quota], 'CPUQuota')}"
      end

      lines.join("\n")
    end
  end
end
