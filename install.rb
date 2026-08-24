#!/usr/bin/env ruby
# frozen_string_literal: true

# Quarks bootstrap installer.

require "etc"
require "English"
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "pathname"
require "rbconfig"
require "rubygems"
require "rubygems/package"
require "securerandom"
require "shellwords"
require "time"
require "tmpdir"

module QuarksBootstrap
  VERSION = "1.0.0"
  PROJECT_ROOT = File.expand_path(__dir__)
  GEMSPEC = File.join(PROJECT_ROOT, "quarks-package-manager.gemspec")
  MINIMUM_RUBY = Gem::Version.new("3.2")
  MAXIMUM_RUBY = Gem::Version.new("4.1.dev")
  MODES = %w[personal managed distribution].freeze

  class Error < StandardError; end

  Options = Struct.new(
    :mode, :prefix, :bindir, :destdir, :user, :home, :yes, :dry_run,
    :color, :dependencies, :setup_path, :action, keyword_init: true
  )

  class UI
    GLYPHS = { info: "●", success: "✓", warning: "!", error: "×", step: "◆" }.freeze
    COLORS = {
      reset: "\e[0m", bold: "\e[1m", dim: "\e[2m", cyan: "\e[36m",
      green: "\e[32m", yellow: "\e[33m", red: "\e[31m"
    }.freeze

    def initialize(input: $stdin, output: $stdout, color: nil)
      @input = input
      @output = output
      @color = color.nil? ? output.tty? && ENV["NO_COLOR"].to_s.empty? : color
    end

    def banner
      @output.puts
      @output.puts paint("  ◈  QUARKS", :bold, :cyan)
      @output.puts paint("     Secure source package management for Linux", :dim)
      @output.puts
    end

    def say(message = "") = @output.puts(message)

    def status(kind, message)
      color = { success: :green, warning: :yellow, error: :red, step: :cyan }.fetch(kind, :cyan)
      @output.puts "  #{paint(GLYPHS.fetch(kind, GLYPHS[:info]), color)}  #{message}"
    end

    def section(title)
      @output.puts
      @output.puts paint("  #{title}", :bold)
    end

    def detail(label, value)
      @output.puts "    #{paint(label.to_s.ljust(16), :dim)} #{value}"
    end

    def choose(question, choices, default: 0)
      raise Error, "Interactive input is required; pass --mode and --yes" unless @input.tty?

      section(question)
      choices.each_with_index do |choice, index|
        marker = index == default ? paint("●", :cyan) : "○"
        @output.puts "    #{marker}  #{index + 1}) #{choice.fetch(:label)}"
        @output.puts "       #{paint(choice.fetch(:description), :dim)}"
      end
      loop do
        @output.print "\n    Choice [#{default + 1}]: "
        @output.flush
        raw = @input.gets
        raise Error, "Input closed" unless raw
        raw = raw.strip
        return choices.fetch(default).fetch(:value) if raw.empty?
        index = Integer(raw, exception: false)
        return choices.fetch(index - 1).fetch(:value) if index&.between?(1, choices.length)
        status(:warning, "Enter a number from 1 to #{choices.length}.")
      end
    end

    def ask(question, default: nil)
      raise Error, "Interactive input is required" unless @input.tty?
      suffix = default ? " [#{default}]" : ""
      @output.print "    #{question}#{suffix}: "
      @output.flush
      raw = @input.gets
      raise Error, "Input closed" unless raw
      value = raw.strip
      value.empty? ? default : value
    end

    def confirm(question, default: true)
      raise Error, "Interactive input is required; pass --yes to continue" unless @input.tty?
      hint = default ? "Y/n" : "y/N"
      loop do
        @output.print "\n    #{question} [#{hint}] "
        @output.flush
        answer = @input.gets
        raise Error, "Input closed" unless answer
        answer = answer.strip.downcase
        return default if answer.empty?
        return true if %w[y yes].include?(answer)
        return false if %w[n no].include?(answer)
      end
    end

    private

    def paint(text, *styles)
      return text unless @color
      styles.map { |style| COLORS.fetch(style) }.join + text + COLORS[:reset]
    end
  end

  class Runner
    TRUSTED_DIRS = [
      RbConfig::CONFIG["bindir"], Gem.bindir,
      "/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/host/bin", "/usr/host/sbin"
    ].compact.map { |path| File.expand_path(path) }.uniq.freeze

    attr_reader :dry_run

    def initialize(ui, dry_run: false)
      @ui = ui
      @dry_run = dry_run
    end

    def run(*argv, env: {}, chdir: nil, privileged: false, as_user: nil)
      command = argv.flatten.map(&:to_s)
      command[0] = trusted_command(command.fetch(0))
      command = privilege_prefix(as_user) + command if privileged || as_user
      shown_env = env.map { |key, value| "#{key}=#{Shellwords.escape(value.to_s)}" }
      @ui.status(:step, (shown_env + command.map { |arg| Shellwords.escape(arg) }).join(" "))
      return true if dry_run

      options = {}
      options[:chdir] = chdir if chdir
      success = system(env, *command, **options)
      return true if success

      code = $CHILD_STATUS&.exitstatus
      raise Error, "Command failed#{" with exit status #{code}" if code}: #{command.first}"
    end

    def command?(name)
      !trusted_command(name, required: false).nil?
    end

    private

    def trusted_command(command, required: true)
      if command.include?(File::SEPARATOR)
        path = File.expand_path(command)
        return path if File.file?(path) && File.executable?(path) && !File.symlink?(path)
        raise Error, "Executable not found or unsafe: #{command}" if required
        return nil
      end
      candidates = TRUSTED_DIRS.map { |directory| File.join(directory, command) }
      path = candidates.filter_map do |candidate|
        next unless File.file?(candidate) && File.executable?(candidate)
        link_stat = File.lstat(candidate)
        next unless link_stat.uid.zero? && (link_stat.symlink? || (link_stat.mode & 0o022).zero?)
        resolved = File.realpath(candidate)
        stat = File.stat(resolved)
        resolved if stat.file? && stat.uid.zero? && (stat.mode & 0o022).zero?
      rescue SystemCallError
        nil
      end.first
      raise Error, "Trusted executable not found: #{command}" if required && !path
      path
    end

    def privilege_prefix(as_user)
      if as_user && Etc.getpwuid(Process.euid).name == as_user
        return []
      end
      if Process.euid.zero?
        return [] unless as_user
        runuser = %w[/usr/sbin/runuser /sbin/runuser /usr/bin/runuser].find { |path| File.executable?(path) }
        return [runuser, "-u", as_user, "--"] if runuser
        raise Error, "runuser is required to install as #{as_user}"
      end

      sudo = trusted_command("sudo", required: false)
      raise Error, "sudo is required for this installation mode" unless sudo
      as_user ? [sudo, "-u", as_user, "--"] : [sudo, "--"]
    end
  end

  class Installer
    REQUIRED_COMMANDS = %w[gem].freeze
    RUNTIME_COMMANDS = %w[bwrap gpg gpgv tar unzip patch].freeze

    def initialize(options, ui: UI.new(color: options.color), runner: nil)
      @options = options
      @ui = ui
      @runner = runner || Runner.new(ui, dry_run: options.dry_run)
    end

    def run
      @ui.banner
      validate_host!
      resolve_interactive_options!
      apply_defaults!
      validate_options!
      show_plan
      verb = { "install" => "Install", "uninstall" => "Uninstall", "purge" => "Purge" }.fetch(@options.action)
      unless @options.yes || @ui.confirm("#{verb} Quarks with this configuration?")
        @ui.status(:warning, "#{verb} cancelled; nothing was changed.")
        return false
      end

      if @runner.dry_run
        @options.action == "install" ? install! : uninstall!(purge: @options.action == "purge")
      else
        begin
          @account_created = provision_user! if @options.mode == "managed" && @options.action == "install"
          with_lifecycle_lock do
            recover_interrupted_transaction!
            if @options.action == "install"
              install!
            else
              uninstall!(purge: @options.action == "purge")
            end
          end
        rescue Exception
          rollback_created_account! if @account_created && !@install_committed
          raise
        end
      end
      finish
      true
    end

    private

    def validate_host!
      raise Error, "Quarks supports Linux only" unless RUBY_PLATFORM.include?("linux")
      current = Gem::Version.new(RUBY_VERSION)
      unless current >= MINIMUM_RUBY && current < MAXIMUM_RUBY
        raise Error, "Ruby 3.2 through 4.0 is required (found #{RUBY_VERSION})"
      end
      if @options.action.to_s.empty? || @options.action == "install"
        raise Error, "Missing project gemspec: #{GEMSPEC}" unless File.file?(GEMSPEC)
        missing = REQUIRED_COMMANDS.reject { |command| @runner.command?(command) }
        raise Error, "Missing required command(s): #{missing.join(', ')}" unless missing.empty?
      end

      absent = RUNTIME_COMMANDS.reject { |command| @runner.command?(command) }
      if absent.empty?
        @ui.status(:success, "Host checks passed — Ruby #{RUBY_VERSION} and build isolation tools are available.")
      else
        @ui.status(:warning, "Quarks can be installed, but package builds need: #{absent.join(', ')}")
      end
    end

    def resolve_interactive_options!
      return if @options.mode
      raise Error, "--mode is required with --yes" if @options.yes

      @options.mode = @ui.choose(
        "Choose an installation profile",
        [
          { value: "personal", label: "Personal", description: "Install for the current user; no root access required." },
          { value: "managed", label: "Dedicated account", description: "Create a quarks Linux user and publish the command system-wide." },
          { value: "distribution", label: "Distribution / LFS", description: "Stage package files under DESTDIR without changing the host." }
        ]
      )
    end

    def apply_defaults!
      @options.action ||= "install"
      case @options.mode
      when "personal"
        home = Dir.home
        @options.home ||= home
        @options.prefix ||= File.join(home, ".local", "share", "quarks")
        @options.bindir ||= File.join(home, ".local", "bin")
        @options.dependencies = true if @options.dependencies.nil?
        @options.setup_path = false if @options.setup_path.nil?
      when "managed"
        @options.user ||= "quarks"
        @options.home ||= "/home/#{@options.user}"
        @options.prefix ||= File.join(@options.home, ".local", "share", "quarks")
        @options.bindir ||= "/usr/local/bin"
        @options.dependencies = true if @options.dependencies.nil?
      when "distribution"
        @options.destdir ||= ENV["DESTDIR"].to_s
        if @options.destdir.to_s.empty? && !@options.yes
          @options.destdir = @ui.ask("Staging directory (DESTDIR)", default: File.join(Dir.pwd, "pkg"))
        end
        @options.prefix ||= "/usr/lib/quarks"
        @options.bindir ||= "/usr/bin"
        @options.dependencies = false if @options.dependencies.nil?
      end
    end

    def validate_options!
      raise Error, "Unknown action #{@options.action.inspect}" unless %w[install uninstall purge].include?(@options.action)
      raise Error, "Unknown mode #{@options.mode.inspect}" unless MODES.include?(@options.mode)
      if @options.mode == "personal" && Process.euid.zero?
        raise Error, "Personal installs must run as the target user, without sudo; use managed mode for a dedicated account"
      end
      validate_absolute_path!("prefix", @options.prefix)
      validate_absolute_path!("bindir", @options.bindir)
      if @options.mode == "distribution"
        raise Error, "--destdir is required for distribution mode" if @options.destdir.to_s.empty?
        validate_absolute_path!("destdir", @options.destdir)
        raise Error, "DESTDIR must not be /" if clean_path(@options.destdir) == "/"
      end
      if @options.mode == "managed"
        unless @options.user.match?(/\A[a-z_][a-z0-9_-]{0,30}\z/)
          raise Error, "Invalid managed account name: #{@options.user.inspect}"
        end
        validate_absolute_path!("home", @options.home)
        raise Error, "Managed installs cannot target the root account" if @options.user == "root"
      end
    end

    def validate_absolute_path!(label, value)
      raise Error, "#{label} must be an absolute path" unless value && Pathname.new(value).absolute?
      raise Error, "#{label} contains a NUL byte" if value.include?("\0")
      expanded = clean_path(value)
      raise Error, "Refusing unsafe #{label}: #{value}" if expanded == "/" || expanded.split("/").include?("..")
    end

    def clean_path(path) = File.expand_path(path)

    def show_plan
      @ui.section("#{@options.action.capitalize} plan")
      @ui.detail("Action", @options.action)
      @ui.detail("Profile", @options.mode)
      @ui.detail("Ruby", "#{RbConfig.ruby} (#{RUBY_VERSION})")
      @ui.detail("Gem home", installed_path(@options.prefix))
      @ui.detail("Command", installed_path(File.join(@options.bindir, "quarks")))
      @ui.detail("Dependencies", @options.dependencies ? "install with RubyGems" : "provided by the distribution")
      @ui.detail("Account", @options.user) if @options.mode == "managed"
      @ui.detail("DESTDIR", @options.destdir) if @options.mode == "distribution"
      @ui.detail("Execution", "dry run — commands will only be printed") if @options.dry_run
    end

    def provision_user!
      return false if user_exists?(@options.user)
      @ui.section("Provisioning account")
      useradd = %w[/usr/sbin/useradd /sbin/useradd].find { |path| File.executable?(path) } || "useradd"
      @runner.run(
        useradd, "--create-home", "--home-dir", @options.home,
        "--shell", preferred_shell, "--comment", "Quarks package manager", @options.user,
        privileged: true
      )
      true
    end

    def rollback_created_account!
      return unless user_exists?(@options.user)
      identity = Etc.getpwnam(@options.user)
      return unless File.expand_path(identity.dir) == File.expand_path(@options.home)
      userdel = %w[/usr/sbin/userdel /sbin/userdel].find { |path| File.executable?(path) } || "userdel"
      @runner.run(userdel, "--remove", @options.user, privileged: true)
    rescue => e
      @ui.status(:warning, "Installation rollback could not remove newly created account #{@options.user}: #{e.message}")
    end

    def user_exists?(name)
      Etc.getpwnam(name)
      true
    rescue ArgumentError
      false
    end

    def preferred_shell
      File.executable?("/bin/bash") ? "/bin/bash" : "/bin/sh"
    end

    def install!
      @ui.section("Installing Quarks")
      Dir.mktmpdir("quarks-bootstrap-") do |temporary|
        artifact = File.join(temporary, "quarks-package-manager.gem")
        @runner.run("gem", "build", GEMSPEC, "--output", artifact, chdir: PROJECT_ROOT)
        return verify_install! if @runner.dry_run

        version = Gem::Package.new(artifact).spec.version.to_s
        validate_existing_install!
        stage_prefix = sibling_path(live_prefix, "stage")
        stage_launcher = sibling_path(launcher_path, "stage")
        create_stage_prefix!(stage_prefix)
        install_gem!(artifact, stage_prefix)
        verify_gem_home!(stage_prefix, version)
        write_file!(stage_launcher, launcher_content(version), mode: 0o755)
        commit_install!(stage_prefix, stage_launcher, version)
      ensure
        remove_tree!(stage_prefix) if defined?(stage_prefix) && stage_prefix && path_exists?(stage_prefix)
        remove_file!(stage_launcher) if defined?(stage_launcher) && stage_launcher && path_exists?(stage_launcher)
      end
    end

    def primary_group
      Etc.getpwnam(@options.user).gid.then { |gid| Etc.getgrgid(gid).name }
    rescue ArgumentError
      @options.user
    end

    def install_gem!(artifact, destination)
      argv = ["gem", "install", "--no-document", "--install-dir", destination]
      argv << "--ignore-dependencies" unless @options.dependencies
      argv << artifact
      env = { "GEM_HOME" => destination, "GEM_PATH" => destination }

      case @options.mode
      when "managed"
        env["HOME"] = @options.home
        @runner.run(*argv, env: env, privileged: true, as_user: @options.user)
      else
        @runner.run(*argv, env: env)
      end
    end

    def launcher_content(version)
      <<~RUBY
        #!/usr/bin/env ruby
        # Generated by the Quarks bootstrap installer.
        require "rubygems"
        quarks_gem_home = #{@options.prefix.inspect}
        ENV["QUARKS_INSTALL_RECEIPT"] = #{deployed_receipt_path.inspect}
        ENV["GEM_HOME"] = quarks_gem_home
        ENV["GEM_PATH"] = ([quarks_gem_home] + Gem.default_path).uniq.join(File::PATH_SEPARATOR)
        Gem.clear_paths
        load Gem.activate_bin_path("quarks-package-manager", "quarks", #{version.inspect})
      RUBY
    end

    def verify_install!
      return @ui.status(:success, "Dry run completed; no files were changed.")
    end

    def verify_gem_home!(prefix, version)
      executable = File.join(prefix, "bin", "quarks")
      gem_path = @options.dependencies ? prefix : ([prefix] + Gem.default_path).uniq.join(File::PATH_SEPARATOR)
      env = { "GEM_HOME" => prefix, "GEM_PATH" => gem_path }
      if @options.mode == "managed"
        env["HOME"] = @options.home
        @runner.run(executable, "version", env: env, privileged: true, as_user: @options.user)
      else
        @runner.run(executable, "version", env: env)
      end
      spec = Dir[File.join(prefix, "specifications", "quarks-package-manager-*.gemspec")]
      raise Error, "Staged payload does not contain Quarks #{version}" unless spec.any? { |path| File.basename(path) == "quarks-package-manager-#{version}.gemspec" }
    end

    def live_prefix
      installed_path(@options.prefix)
    end

    def launcher_path
      installed_path(File.join(@options.bindir, "quarks"))
    end

    def receipt_path
      if @options.mode == "managed"
        return File.join("/var", "lib", "quarks-bootstrap", "#{@options.user}.json")
      end
      File.join(File.dirname(live_prefix), ".#{File.basename(live_prefix)}-install.json")
    end

    def deployed_receipt_path
      return "/var/lib/quarks-bootstrap/#{@options.user}.json" if @options.mode == "managed"
      return File.join(File.dirname(@options.prefix), ".#{File.basename(@options.prefix)}-install.json") if @options.mode == "distribution"
      receipt_path
    end

    def backup_root
      File.join(File.dirname(live_prefix), ".#{File.basename(live_prefix)}-backups")
    end

    def transaction_journal_path
      if @options.mode == "managed"
        return File.join("/var", "lib", "quarks-bootstrap", ".#{@options.user}-transaction.json")
      end
      File.join(File.dirname(live_prefix), ".#{File.basename(live_prefix)}-transaction.json")
    end

    def with_lifecycle_lock
      directories = if @options.mode == "managed"
                      metadata = "/var/lib/quarks-bootstrap"
                      @runner.run("install", "-d", "-m", "0755", metadata, privileged: true)
                      stat = File.stat(metadata)
                      raise Error, "Managed lifecycle lock directory is unsafe" unless stat.uid.zero? && (stat.mode & 0o022).zero?
                      @runner.run("mkdir", "-p", "--", File.dirname(live_prefix), as_user: @options.user)
                      @runner.run("install", "-d", "-m", "0755", File.dirname(launcher_path), privileged: true)
                      [metadata, File.dirname(live_prefix), File.dirname(launcher_path)].uniq.sort
                    else
                      [File.dirname(live_prefix), File.dirname(launcher_path)].uniq.sort
                    end
      directories = (directories + [Dir.tmpdir]).uniq.sort
      directories.each do |directory|
        prepare_parent!(directory) unless @options.mode == "managed"
        validate_no_symlink_ancestors!(directory)
      end
      locks = directories.map { |directory| File.open(directory, File::RDONLY) }
      begin
        locks.each { |lock| lock.flock(File::LOCK_EX) }
        yield
      ensure
        locks.reverse_each(&:close)
      end
    end

    def sibling_path(path, purpose)
      File.join(File.dirname(path), ".#{File.basename(path)}.#{purpose}-#{Process.pid}-#{SecureRandom.hex(6)}")
    end

    def create_stage_prefix!(path)
      if @options.mode == "managed"
        @runner.run("mkdir", "-p", "--", File.dirname(path), as_user: @options.user)
        @runner.run("mkdir", "--", path, as_user: @options.user)
      else
        prepare_parent!(File.dirname(path))
        FileUtils.mkdir(path, mode: 0o755)
      end
    end

    def prepare_parent!(path, owner: nil)
      validate_no_symlink_ancestors!(path)
      if @options.mode == "managed"
        if owner
          @runner.run("mkdir", "-p", "--", path, as_user: owner)
        else
          @runner.run("install", "-d", "-m", "0755", path, privileged: true)
        end
      else
        FileUtils.mkdir_p(path, mode: 0o755)
      end
    end

    def write_file!(path, content, mode:, owner: nil)
      prepare_parent!(File.dirname(path), owner: owner)
      if @options.mode == "managed"
        Dir.mktmpdir("quarks-publish-") do |directory|
          source = File.join(directory, File.basename(path))
          File.binwrite(source, content)
          File.chmod(0o644, source)
          argv = ["install", "-m", format("%04o", mode)]
          if owner
            File.chmod(0o755, directory)
            @runner.run(*argv, source, path, as_user: owner)
          else
            @runner.run(*argv, source, path, privileged: true)
          end
        end
      else
        begin
          temporary = sibling_path(path, "write")
          File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
            file.write(content)
            file.flush
            file.fsync
          end
          File.chmod(mode, temporary)
          File.rename(temporary, path)
          fsync_directory(File.dirname(path))
        ensure
          FileUtils.rm_f(temporary) if defined?(temporary) && temporary
        end
      end
    end

    def move_path!(source, destination)
      validate_no_symlink_ancestors!(source)
      validate_no_symlink_ancestors!(File.dirname(destination))
      if @options.mode == "managed"
        if managed_payload_path?(source) && managed_payload_path?(destination)
          @runner.run("mv", "--", source, destination, as_user: @options.user)
        else
          @runner.run("mv", "--", source, destination, privileged: true)
        end
      else
        File.rename(source, destination)
        fsync_directory(File.dirname(source))
        fsync_directory(File.dirname(destination)) unless File.dirname(source) == File.dirname(destination)
      end
    end

    def remove_tree!(path)
      return unless path_exists?(path)
      validate_removal_path!(path)
      if @options.mode == "managed"
        if managed_user_path?(path)
          @runner.run("rm", "-rf", "--", path, as_user: @options.user)
        else
          @runner.run("rm", "-rf", "--", path, privileged: true)
        end
      else
        FileUtils.rm_rf(path)
      end
    end

    def remove_file!(path)
      return unless path_exists?(path)
      validate_no_symlink_ancestors!(path)
      if @options.mode == "managed"
        if managed_user_path?(path)
          @runner.run("rm", "-f", "--", path, as_user: @options.user)
        else
          @runner.run("rm", "-f", "--", path, privileged: true)
        end
      else
        FileUtils.rm_f(path)
      end
    end

    def path_exists?(path)
      File.exist?(path) || File.symlink?(path)
    end

    def managed_payload_path?(path)
      expanded = File.expand_path(path.to_s)
      parent = File.expand_path(File.dirname(live_prefix))
      expanded == parent || expanded.start_with?("#{parent}/")
    end

    def managed_user_path?(path)
      expanded = File.expand_path(path.to_s)
      home = File.expand_path(@options.home)
      expanded == home || expanded.start_with?("#{home}/")
    end

    def validate_removal_path!(path)
      expanded = File.expand_path(path.to_s)
      raise Error, "Refusing unsafe removal path: #{path}" if expanded == "/" || expanded.empty?
      allowed = [File.dirname(live_prefix), File.dirname(launcher_path), @options.home].compact.map { |root| File.expand_path(root) }
      unless allowed.any? { |root| expanded.start_with?("#{root}/") }
        raise Error, "Refusing removal outside installation roots: #{path}"
      end
      validate_no_symlink_ancestors!(path)
    end

    def validate_no_symlink_ancestors!(path)
      expanded = File.expand_path(path.to_s)
      current = expanded
      loop do
        raise Error, "Refusing symlinked installation path: #{current}" if File.symlink?(current)
        parent = File.dirname(current)
        break if parent == current
        current = parent
      end
      true
    end

    def fsync_directory(path)
      File.open(path, File::RDONLY) { |directory| directory.fsync }
    rescue Errno::EINVAL, Errno::EISDIR
      nil
    end

    def validate_existing_install!
      receipt = load_receipt(required: false)
      if receipt
        validate_receipt!(receipt)
        @existing_receipt = receipt
        return
      end
      return unless path_exists?(live_prefix) || path_exists?(launcher_path)
      return if legacy_install?

      raise Error, "Existing prefix or launcher is not owned by the Quarks bootstrap installer; refusing to replace it"
    end

    def legacy_install?
      specs = Dir[File.join(live_prefix, "specifications", "quarks-package-manager-*.gemspec")]
      launcher = File.file?(launcher_path) ? File.read(launcher_path, 16 * 1024) : ""
      !specs.empty? && launcher.include?("Generated by the Quarks bootstrap installer") && launcher.include?(@options.prefix.inspect)
    rescue
      false
    end

    def commit_install!(stage_prefix, stage_launcher, version)
      token = "#{Time.now.utc.strftime('%Y%m%d%H%M%S')}-#{SecureRandom.hex(4)}"
      validate_no_symlink_ancestors!(backup_root)
      if @options.mode == "managed"
        @runner.run("mkdir", "-p", "--", backup_root, as_user: @options.user)
        @runner.run("chmod", "0700", "--", backup_root, as_user: @options.user)
      else
        prepare_parent!(backup_root)
      end
      backup_prefix = File.join(backup_root, "#{File.basename(live_prefix)}-#{token}")
      backup_launcher = sibling_path(launcher_path, "backup")
      backup_receipt = sibling_path(receipt_path, "backup")
      prefix_backed_up = launcher_backed_up = receipt_backed_up = false
      prefix_published = launcher_published = receipt_published = false
      journal = {
        "schema_version" => 1,
        "live_prefix" => live_prefix,
        "launcher" => launcher_path,
        "receipt" => receipt_path,
        "stage_prefix" => stage_prefix,
        "stage_launcher" => stage_launcher,
        "backup_prefix" => backup_prefix,
        "backup_launcher" => backup_launcher,
        "backup_receipt" => backup_receipt,
        "had_prefix" => path_exists?(live_prefix),
        "had_launcher" => path_exists?(launcher_path),
        "had_receipt" => path_exists?(receipt_path),
        "prefix_backed_up" => false,
        "prefix_published" => false,
        "launcher_backed_up" => false,
        "launcher_published" => false,
        "receipt_backed_up" => false,
        "receipt_published" => false
      }
      write_journal!(journal)

      begin
        if path_exists?(live_prefix)
          move_path!(live_prefix, backup_prefix)
          prefix_backed_up = true
          journal["prefix_backed_up"] = true
          write_journal!(journal)
        end
        move_path!(stage_prefix, live_prefix)
        prefix_published = true
        journal["prefix_published"] = true
        write_journal!(journal)

        prepare_parent!(File.dirname(launcher_path))
        if path_exists?(launcher_path)
          move_path!(launcher_path, backup_launcher)
          launcher_backed_up = true
          journal["launcher_backed_up"] = true
          write_journal!(journal)
        end
        move_path!(stage_launcher, launcher_path)
        launcher_published = true
        journal["launcher_published"] = true
        write_journal!(journal)

        if path_exists?(receipt_path)
          move_path!(receipt_path, backup_receipt)
          receipt_backed_up = true
          journal["receipt_backed_up"] = true
          write_journal!(journal)
        end
        write_receipt!(version, backup_prefix: prefix_backed_up ? backup_prefix : nil)
        receipt_published = true
        journal["receipt_published"] = true
        write_journal!(journal)
        verify_committed_install!(version)
      rescue Exception
        remove_file!(receipt_path) if receipt_published
        move_path!(backup_receipt, receipt_path) if receipt_backed_up && path_exists?(backup_receipt)
        remove_file!(launcher_path) if launcher_published
        move_path!(backup_launcher, launcher_path) if launcher_backed_up && path_exists?(backup_launcher)
        remove_tree!(live_prefix) if prefix_published && path_exists?(live_prefix)
        move_path!(backup_prefix, live_prefix) if prefix_backed_up && path_exists?(backup_prefix)
        remove_file!(transaction_journal_path)
        raise
      end

      remove_file!(transaction_journal_path)
      @install_committed = true
      remove_file!(backup_launcher) if path_exists?(backup_launcher)
      remove_file!(backup_receipt) if path_exists?(backup_receipt)
      prune_backups!
    end

    def write_journal!(journal)
      mode = @options.mode == "managed" ? 0o644 : 0o600
      write_file!(transaction_journal_path, JSON.generate(journal) + "\n", mode: mode)
    end

    def recover_interrupted_transaction!
      return unless File.file?(transaction_journal_path) && !File.symlink?(transaction_journal_path)
      raise Error, "Install transaction journal is too large" if File.size(transaction_journal_path) > 65_536
      journal_stat = File.stat(transaction_journal_path)
      expected_owner = @options.mode == "managed" ? 0 : Process.euid
      if journal_stat.uid != expected_owner || (journal_stat.mode & 0o022).positive?
        raise Error, "Install transaction journal has unsafe ownership or permissions"
      end
      journal = JSON.parse(File.read(transaction_journal_path))
      validate_journal!(journal)
      @ui.status(:warning, "Recovering an interrupted Quarks installation transaction")

      if journal["had_receipt"] && path_exists?(journal["backup_receipt"])
        remove_file!(receipt_path)
        move_path!(journal["backup_receipt"], receipt_path)
      elsif !journal["had_receipt"]
        remove_file!(receipt_path)
      end

      if journal["had_launcher"] && path_exists?(journal["backup_launcher"])
        remove_file!(launcher_path)
        move_path!(journal["backup_launcher"], launcher_path)
      elsif !journal["had_launcher"]
        remove_file!(launcher_path)
      end

      if journal["had_prefix"] && path_exists?(journal["backup_prefix"])
        remove_tree!(live_prefix) if path_exists?(live_prefix)
        move_path!(journal["backup_prefix"], live_prefix)
      elsif !journal["had_prefix"]
        remove_tree!(live_prefix) if path_exists?(live_prefix)
      end

      remove_tree!(journal["stage_prefix"]) if path_exists?(journal["stage_prefix"])
      remove_file!(journal["stage_launcher"]) if path_exists?(journal["stage_launcher"])
      remove_file!(transaction_journal_path)
    rescue JSON::ParserError => e
      raise Error, "Install transaction journal is corrupt: #{e.message}"
    end

    def validate_journal!(journal)
      valid = journal["schema_version"] == 1 && journal["live_prefix"] == live_prefix &&
              journal["launcher"] == launcher_path && journal["receipt"] == receipt_path &&
              transaction_path?(journal["stage_prefix"], live_prefix, "stage") &&
              transaction_path?(journal["stage_launcher"], launcher_path, "stage") &&
              transaction_path?(journal["backup_launcher"], launcher_path, "backup") &&
              transaction_path?(journal["backup_receipt"], receipt_path, "backup") &&
              File.dirname(journal["backup_prefix"].to_s) == backup_root &&
              File.basename(journal["backup_prefix"].to_s).match?(%r{\A#{Regexp.escape(File.basename(live_prefix))}-\d{14}-[0-9a-f]{8}\z})
      raise Error, "Install transaction journal contains unsafe paths" unless valid
    end

    def transaction_path?(candidate, target, purpose)
      return false unless candidate.is_a?(String) && File.dirname(candidate) == File.dirname(target)
      File.basename(candidate).match?(%r{\A\.#{Regexp.escape(File.basename(target))}\.#{purpose}-\d+-[0-9a-f]{12}\z})
    end

    def verify_committed_install!(version)
      return if @options.mode == "distribution"
      gem_path = @options.dependencies ? @options.prefix : ([@options.prefix] + Gem.default_path).uniq.join(File::PATH_SEPARATOR)
      env = { "GEM_HOME" => @options.prefix, "GEM_PATH" => gem_path }
      if @options.mode == "managed"
        env["HOME"] = @options.home
        @runner.run(launcher_path, "version", env: env, privileged: true, as_user: @options.user)
      else
        @runner.run(launcher_path, "version", env: env)
      end
      receipt = load_receipt(required: true)
      raise Error, "Installed receipt version mismatch" unless receipt.dig("installed", "version") == version
    end

    def write_receipt!(version, backup_prefix: nil)
      account_created = !!@account_created || @existing_receipt&.dig("installation", "account_created") == true
      data = {
        "schema_version" => 1,
        "installation" => {
          "mode" => @options.mode,
          "prefix" => @options.prefix,
          "installed_prefix" => live_prefix,
          "bindir" => @options.bindir,
          "launcher" => launcher_path,
          "dependencies" => !!@options.dependencies,
          "user" => @options.user,
          "home" => @options.home,
          "data_roots" => runtime_data_paths(File.expand_path(@options.home || Dir.home), receipt: @existing_receipt),
          "uid" => managed_identity&.uid,
          "gid" => managed_identity&.gid,
          "account_created" => account_created
        },
        "installed" => {
          "version" => version,
          "installed_at" => Time.now.utc.iso8601,
          "launcher_sha256" => Digest::SHA256.file(launcher_path).hexdigest,
          "backup_prefix" => backup_prefix
        },
        "source" => source_metadata
      }
      write_file!(receipt_path, JSON.pretty_generate(data) + "\n", mode: @options.mode == "managed" ? 0o644 : 0o600)
    end

    def load_receipt(required:)
      unless File.file?(receipt_path) && !File.symlink?(receipt_path)
        raise Error, "Quarks install receipt is missing: #{receipt_path}" if required
        return nil
      end
      raise Error, "Quarks install receipt is too large" if File.size(receipt_path) > 65_536
      stat = File.stat(receipt_path)
      expected_owner = @options.mode == "managed" ? 0 : Process.euid
      if stat.uid != expected_owner || (stat.mode & 0o022).positive?
        raise Error, "Quarks install receipt has unsafe ownership or permissions"
      end
      JSON.parse(File.read(receipt_path))
    rescue JSON::ParserError => e
      raise Error, "Quarks install receipt is corrupt: #{e.message}"
    end

    def validate_receipt!(receipt)
      expected = receipt["installation"]
      valid = receipt["schema_version"] == 1 && expected.is_a?(Hash) &&
              expected["mode"] == @options.mode && expected["prefix"] == @options.prefix &&
              expected["installed_prefix"] == live_prefix && expected["bindir"] == @options.bindir &&
              expected["launcher"] == launcher_path && expected["user"] == @options.user &&
              expected["home"] == @options.home
      if valid && @options.mode == "managed"
        identity = managed_identity
        valid = identity && expected["uid"] == identity.uid && expected["gid"] == identity.gid &&
                File.expand_path(identity.dir) == File.expand_path(@options.home)
      end
      raise Error, "Install receipt does not match the requested installation" unless valid
      true
    end

    def managed_identity
      return nil unless @options.mode == "managed"
      Etc.getpwnam(@options.user)
    rescue ArgumentError
      nil
    end

    def source_metadata
      git = %w[/usr/bin/git /bin/git].find { |path| File.file?(path) && File.executable?(path) }
      return { "managed" => false, "reason" => "git_unavailable" } unless git
      root, root_status = git_capture(git, "-C", PROJECT_ROOT, "rev-parse", "--show-toplevel")
      return { "managed" => false, "reason" => "not_a_git_checkout" } unless root_status.success? && File.expand_path(root.strip) == PROJECT_ROOT
      dirty, dirty_status = git_capture(git, "-C", PROJECT_ROOT, "status", "--porcelain", "--untracked-files=normal")
      return { "managed" => false, "reason" => "dirty_checkout" } unless dirty_status.success? && dirty.empty?
      branch, branch_status = git_capture(git, "-C", PROJECT_ROOT, "symbolic-ref", "--quiet", "--short", "HEAD")
      return { "managed" => false, "reason" => "detached_head" } unless branch_status.success?
      branch = branch.strip
      return { "managed" => false, "reason" => "invalid_tracking_branch" } unless branch.match?(%r{\A[A-Za-z0-9][A-Za-z0-9._/-]*\z}) && !branch.include?("..")
      upstream, upstream_status = git_capture(git, "-C", PROJECT_ROOT, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}")
      return { "managed" => false, "reason" => "missing_upstream" } unless upstream_status.success? && upstream.strip == "origin/#{branch}"
      url, url_status = git_capture(git, "-C", PROJECT_ROOT, "config", "--get", "remote.origin.url")
      commit, commit_status = git_capture(git, "-C", PROJECT_ROOT, "rev-parse", "HEAD")
      url = url.strip
      valid_url = url.match?(%r{\Ahttps://[^\s/@]+(?:/[^\s]*)?\z}) && !url.include?("@")
      unless url_status.success? && commit_status.success? && valid_url && commit.strip.match?(/\A[0-9a-f]{40,64}\z/)
        return { "managed" => false, "reason" => "untrusted_upstream" }
      end
      fingerprint = git_signature_fingerprint(git, commit.strip)
      return { "managed" => false, "reason" => "unsigned_checkout" } unless fingerprint
      signing_key = export_signing_key(fingerprint)
      return { "managed" => false, "reason" => "signing_key_unavailable" } unless signing_key
      {
        "managed" => @options.mode != "distribution",
        "url" => url,
        "branch" => branch,
        "tracking_ref" => "refs/heads/#{branch}",
        "commit" => commit.strip,
        "signing_fingerprint" => fingerprint,
        "signing_key" => signing_key
      }
    rescue
      { "managed" => false, "reason" => "provenance_error" }
    end

    def git_capture(git, *args)
      env = {
        "PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C",
        "HOME" => Dir.mktmpdir("quarks-git-home-"),
        "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
        "GIT_TERMINAL_PROMPT" => "0"
      }
      Open3.capture2(env, git, "-c", "core.hooksPath=/dev/null", "-c", "credential.helper=", *args, unsetenv_others: true)
    ensure
      FileUtils.rm_rf(env["HOME"]) if defined?(env) && env && env["HOME"]
    end

    def git_signature_fingerprint(git, commit)
      gpg = %w[/usr/bin/gpg /bin/gpg /usr/bin/gpg2].find { |path| File.file?(path) && File.executable?(path) }
      return nil unless gpg
      env = {
        "PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C", "HOME" => Dir.home,
        "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null"
      }
      output, error, status = Open3.capture3(
        env, git, "-c", "core.hooksPath=/dev/null", "-c", "gpg.program=#{gpg}",
        "-C", PROJECT_ROOT, "verify-commit", "--raw", commit,
        unsetenv_others: true
      )
      return nil unless status.success?
      match = "#{output}\n#{error}".match(/^\[GNUPG:\] VALIDSIG ([0-9A-F]{40,64})\b/)
      match && match[1]
    rescue
      nil
    end

    def export_signing_key(fingerprint)
      gpg = %w[/usr/bin/gpg /bin/gpg /usr/bin/gpg2].find { |path| File.file?(path) && File.executable?(path) }
      return nil unless gpg
      output, _error, status = Open3.capture3(
        { "PATH" => "/usr/bin:/bin", "LANG" => "C", "LC_ALL" => "C", "HOME" => Dir.home },
        gpg, "--batch", "--armor", "--export", fingerprint,
        unsetenv_others: true
      )
      return nil unless status.success? && output.bytesize.between?(1, 48 * 1024)
      output
    rescue
      nil
    end

    def prune_backups!
      return unless Dir.exist?(backup_root)
      entries = Dir.children(backup_root).map { |name| File.join(backup_root, name) }.select { |path| File.directory?(path) && !File.symlink?(path) }
      entries.sort_by { |path| File.mtime(path) }.reverse.drop(3).each { |path| remove_tree!(path) }
    end

    def uninstall!(purge:)
      @ui.section(purge ? "Purging Quarks" : "Uninstalling Quarks")
      if @runner.dry_run
        @ui.status(:step, "remove #{live_prefix}")
        @ui.status(:step, "remove #{launcher_path}")
        @ui.status(:step, "remove runtime state and configuration") if purge
        return
      end

      receipt = load_receipt(required: false)
      if receipt
        validate_receipt!(receipt)
        validate_launcher_ownership!(receipt)
      elsif path_exists?(live_prefix) || path_exists?(launcher_path)
        raise Error, "Cannot safely uninstall without a matching install receipt" unless legacy_install?
        raise Error, "Cannot fully purge a legacy install without a receipt; reinstall once or use --remove-program-only" if purge
      else
        @ui.status(:success, "Quarks is not installed at the requested prefix.")
        return
      end

      preflight_purge!(receipt) if purge && @options.mode != "distribution"

      remove_file!(launcher_path)
      remove_tree!(live_prefix)
      remove_tree!(backup_root) if path_exists?(backup_root)
      purge_runtime_data!(receipt) if purge && @options.mode != "distribution"
      remove_managed_account!(receipt) if purge && @options.mode == "managed" && receipt
      remove_file!(receipt_path)
      remove_file!(transaction_journal_path)
      @ui.status(:success, purge ? "Quarks and its runtime data were removed." : "Quarks program files were removed; package data was preserved.")
    end

    def validate_launcher_ownership!(receipt)
      return unless path_exists?(launcher_path)
      raise Error, "Installed launcher is a symlink; refusing to remove it" if File.symlink?(launcher_path)
      content = File.read(launcher_path, 65_536)
      raise Error, "Installed launcher is not managed by the bootstrap installer" unless content.include?("Generated by the Quarks bootstrap installer")
      expected = receipt.dig("installed", "launcher_sha256")
      actual = Digest::SHA256.file(launcher_path).hexdigest
      raise Error, "Installed launcher was modified; preserving it" unless expected == actual
    end

    def purge_runtime_data!(receipt)
      home = File.expand_path(@options.home || Dir.home)
      runtime_data_paths(home, receipt: receipt).each { |path| remove_tree!(path) if path_exists?(path) }
      [File.join(home, ".quarks.conf")].each { |path| remove_file!(path) }
      remove_shell_snippets!(home)
    end

    def preflight_purge!(receipt)
      home = File.expand_path(@options.home || Dir.home)
      runtime_data_paths(home, receipt: receipt).each do |path|
        raise Error, "Refusing to purge Quarks data outside #{home}: #{path}" unless path.start_with?("#{home}/")
        validate_no_symlink_ancestors!(path)
      end
      %w[.quarks.conf .zshrc .bashrc .profile].each do |name|
        path = File.join(home, name)
        validate_no_symlink_ancestors!(path)
      end
      validate_managed_account_removal!(receipt) if @options.mode == "managed"
      true
    end

    def runtime_data_paths(home, receipt: nil)
      recorded = receipt&.dig("installation", "data_roots")
      return recorded.map { |path| File.expand_path(path) }.uniq if recorded.is_a?(Array) && recorded.all? { |path| path.is_a?(String) }
      [
        ENV["QUARKS_ROOT"].to_s.empty? ? File.join(home, ".local", "quarks") : File.expand_path(ENV["QUARKS_ROOT"]),
        ENV["QUARKS_STATE_ROOT"].to_s.empty? ? File.join(home, ".local", "state", "quarks") : File.expand_path(ENV["QUARKS_STATE_ROOT"]),
        File.join(ENV["XDG_CONFIG_HOME"].to_s.empty? ? File.join(home, ".config") : File.expand_path(ENV["XDG_CONFIG_HOME"]), "quarks")
      ].uniq
    end

    def remove_shell_snippets!(home)
      %w[.zshrc .bashrc .profile].each do |name|
        path = File.join(home, name)
        next unless File.file?(path) && !File.symlink?(path)
        content = File.read(path)
        updated = content.gsub(/^# >>> quarks setup-path >>>\n.*?^# <<< quarks setup-path <<<\n?/m, "")
        next if updated == content
        mode = File.stat(path).mode & 0o777
        write_file!(path, updated, mode: mode, owner: @options.mode == "managed" ? @options.user : nil)
      end
    end

    def remove_managed_account!(receipt)
      return unless receipt.dig("installation", "account_created") == true
      validate_managed_account_removal!(receipt)
      userdel = %w[/usr/sbin/userdel /sbin/userdel].find { |path| File.executable?(path) } || "userdel"
      @runner.run(userdel, "--remove", @options.user, privileged: true)
    rescue ArgumentError
      nil
    end

    def validate_managed_account_removal!(receipt)
      return true unless receipt&.dig("installation", "account_created") == true
      passwd = Etc.getpwnam(@options.user)
      installed = receipt.fetch("installation")
      valid = passwd.uid == installed["uid"] && passwd.gid == installed["gid"] &&
              File.expand_path(passwd.dir) == File.expand_path(installed["home"]) &&
              File.expand_path(passwd.dir) == File.expand_path(@options.home)
      raise Error, "Managed account identity changed; preserving account" unless valid
      raise Error, "Managed account home is a symlink; preserving account" if File.symlink?(passwd.dir)
      true
    end

    def installed_path(path)
      return clean_path(path) unless @options.mode == "distribution"
      File.join(clean_path(@options.destdir), clean_path(path).delete_prefix("/"))
    end

    def finish
      if @options.dry_run
        @ui.section("Dry run complete")
        @ui.status(:success, "The installation plan is valid and no files were changed.")
        @ui.say "\n    Re-run the command without --dry-run to install."
        @ui.say
        return
      end

      @ui.section("Ready")
      if @options.action != "install"
        if @options.action == "purge"
          @ui.status(:success, "Quarks was fully purged from the selected profile.")
        else
          @ui.status(:success, "Quarks program files were removed; use --uninstall for complete removal.")
        end
        @ui.say
        return
      end
      case @options.mode
      when "personal"
        launcher = File.join(@options.bindir, "quarks")
        @ui.status(:success, "Quarks is installed at #{launcher}")
        unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).include?(@options.bindir)
          @ui.say "\n    Add this to your shell profile:"
          @ui.say "      export PATH=#{Shellwords.escape(@options.bindir)}:\"$PATH\""
        end
        alternatives = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).filter_map do |directory|
          candidate = File.join(directory, "quarks")
          candidate if candidate != launcher && File.file?(candidate) && File.executable?(candidate)
        end
        unless alternatives.empty?
          @ui.say "\n    If your shell still runs an older Quarks, refresh its command cache with hash -r or rehash."
        end
        @ui.say "\n    Next: #{launcher} doctor"
      when "managed"
        @ui.status(:success, "Quarks is installed for #{@options.user} and available at #{@options.bindir}/quarks")
        @ui.say "\n    Manage the shared installation with:"
        @ui.say "      sudo -iu #{@options.user} quarks doctor"
      when "distribution"
        @ui.status(:success, "Package tree staged at #{@options.destdir}")
        @ui.say "\n    Declare runtime dependencies on Ruby >= 3.2, ruby-sqlite3 >= 2.9.5,"
        @ui.say "    bubblewrap, GnuPG, tar, unzip, and patch in your package metadata."
      end
      @ui.say
    end
  end

  module CLI
    module_function

    def parse(argv)
      options = Options.new(color: nil, yes: false, dry_run: false, action: "install")
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: ruby install.rb [options]"
        opts.separator ""
        opts.separator "Install Quarks for a user, a managed account, or a distribution image."
        opts.separator ""
        opts.on("--mode MODE", MODES, "personal, managed, or distribution") { |value| options.mode = value }
        opts.on("--prefix PATH", "Ruby gem installation prefix") { |value| options.prefix = value }
        opts.on("--bindir PATH", "Directory for the quarks launcher") { |value| options.bindir = value }
        opts.on("--destdir PATH", "Staging root (distribution mode)") { |value| options.destdir = value }
        opts.on("--user NAME", "Dedicated account name (managed mode)") { |value| options.user = value }
        opts.on("--home PATH", "Dedicated account home (managed mode)") { |value| options.home = value }
        opts.on("--[no-]dependencies", "Install Ruby gem dependencies") { |value| options.dependencies = value }
        opts.on("--uninstall", "Fully remove Quarks, package data, state, and configuration") do
          raise OptionParser::InvalidOption, "conflicting removal actions" if options.action == "uninstall"
          options.action = "purge"
        end
        opts.on("--purge", "Alias for --uninstall") do
          raise OptionParser::InvalidOption, "--uninstall and --purge are mutually exclusive" if options.action == "uninstall"
          options.action = "purge"
        end
        opts.on("--remove-program-only", "Remove Quarks but preserve package data and configuration") do
          raise OptionParser::InvalidOption, "conflicting removal actions" if options.action == "purge"
          options.action = "uninstall"
        end
        opts.on("--yes", "Accept the plan without prompting") { options.yes = true }
        opts.on("--dry-run", "Print actions without changing the system") { options.dry_run = true }
        opts.on("--[no-]color", "Enable or disable ANSI color") { |value| options.color = value }
        opts.on("-h", "--help", "Show this help") { puts opts; exit }
        opts.on("--version", "Show installer version") { puts "Quarks installer #{VERSION}"; exit }
      end
      parser.parse!(argv)
      raise Error, "Unexpected argument(s): #{argv.join(' ')}" unless argv.empty?
      options
    rescue OptionParser::ParseError => e
      raise Error, "#{e.message}\n#{parser}"
    end

    def run(argv = ARGV)
      options = parse(argv)
      Installer.new(options).run ? 0 : 1
    rescue Interrupt
      warn "\nquarks-install: interrupted"
      130
    rescue Error => e
      warn "quarks-install: #{e.message}"
      1
    end
  end
end

exit QuarksBootstrap::CLI.run if $PROGRAM_NAME == __FILE__
