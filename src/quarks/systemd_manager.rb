# frozen_string_literal: true

require "fileutils"

module Quarks
  class SystemdManager
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
      opts = DEFAULT_OPTIONS.merge(options)

      description = opts[:description] || "#{name} service"
      exec_start = opts[:exec_start]
      exec_stop = opts[:exec_stop] ? "ExecStop=#{opts[:exec_stop]}" : ""
      exec_reload = opts[:exec_reload] ? "ExecReload=#{opts[:exec_reload]}" : ""

      env_vars = opts[:environment]
      env_block = if env_vars.is_a?(Hash) && env_vars.any?
        env_vars.map { |k, v| "Environment=\"#{k}=#{v}\"" }.join("\n")
      elsif env_vars.is_a?(Array)
        env_vars.map { |e| "Environment=\"#{e}\"" }.join("\n")
      elsif env_vars
        "Environment=\"#{env_vars}\""
      else
        ""
      end

      security = generate_security_options(opts)

      service_content = SERVICE_TEMPLATE % {
        description: description,
        service_type: opts[:service_type],
        exec_start: exec_start,
        exec_stop: exec_stop,
        exec_reload: exec_reload,
        restart: opts[:restart],
        restart_sec: opts[:restart_sec],
        user: opts[:user],
        group: opts[:group],
        environment: env_block,
        stdout: opts[:stdout],
        stderr: opts[:stderr],
        security: security
      }.transform_values { |v| v.to_s }

      service_content
    end

    def self.generate_timer_file(name, options = {})
      opts = DEFAULT_OPTIONS.merge(options)

      description = opts[:timer_description] || "#{name} timer"
      service = opts[:service] || "#{name}.service"
      on_calendar = opts[:on_calendar] || "daily"
      persistent = opts[:persistent] ? "yes" : "no"
      randomized_delay = opts[:randomized_delay] || 60

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
      install_root = dest_dir || Database::QUARKS_ROOT

      service_dir = File.join(install_root, "usr", "lib", "systemd", "system")
      FileUtils.mkdir_p(service_dir)

      service_file = File.join(service_dir, "#{service_name}.service")
      File.write(service_file, generate_service_file(service_name, options))

      if options[:timer]
        timer_file = File.join(service_dir, "#{service_name}.timer")
        File.write(timer_file, generate_timer_file(service_name, options))
      end

      {
        service: service_file,
        timer: options[:timer] ? File.join(service_dir, "#{service_name}.timer") : nil
      }
    end

    def self.uninstall_service(name, dest_dir)
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

      system("systemctl enable #{name} 2>/dev/null")
      $?.success?
    end

    def self.disable_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would disable service: #{name}"
        return true
      end

      system("systemctl disable #{name} 2>/dev/null")
      $?.success?
    end

    def self.start_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would start service: #{name}"
        return true
      end

      system("systemctl start #{name} 2>/dev/null")
      $?.success?
    end

    def self.stop_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would stop service: #{name}"
        return true
      end

      system("systemctl stop #{name} 2>/dev/null")
      $?.success?
    end

    def self.restart_service(name, dry_run: false)
      if dry_run
        puts "[quarks] Would restart service: #{name}"
        return true
      end

      system("systemctl restart #{name} 2>/dev/null")
      $?.success?
    end

    def self.service_status(name)
      output = `systemctl status #{name} 2>&1`
      { output: output, running: $?.success? }
    rescue
      { output: "systemctl not available", running: false }
    end

    private

    def self.generate_security_options(opts)
      return "" unless opts[:security]

      security_opts = opts[:security]
      lines = []

      if security_opts[:no_new_privileges]
        lines << "NoNewPrivileges=yes"
      end

      if security_opts[:protect_system]
        lines << "ProtectSystem=#{security_opts[:protect_system]}"
      end

      if security_opts[:private_tmp]
        lines << "PrivateTmp=yes"
      end

      if security_opts[:read_only_paths]
        paths = Array(security_opts[:read_only_paths]).join(" ")
        lines << "ReadOnlyPaths=#{paths}"
      end

      if security_opts[:read_write_paths]
        paths = Array(security_opts[:read_write_paths]).join(" ")
        lines << "ReadWritePaths=#{paths}"
      end

      if security_opts[:capabilities]
        lines << "CapabilityBoundingSet=#{security_opts[:capabilities]}"
      end

      if security_opts[:memory_limit]
        lines << "MemoryLimit=#{security_opts[:memory_limit]}"
      end

      if security_opts[:cpu_quota]
        lines << "CPUQuota=#{security_opts[:cpu_quota]}"
      end

      lines.join("\n")
    end
  end
end
