#!/usr/bin/env ruby
# frozen_string_literal: true

# Quarks bootstrap installer.

require "etc"
require "English"
require "fileutils"
require "optparse"
require "pathname"
require "rbconfig"
require "rubygems"
require "shellwords"
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
    :color, :dependencies, :setup_path, keyword_init: true
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
    attr_reader :dry_run

    def initialize(ui, dry_run: false)
      @ui = ui
      @dry_run = dry_run
    end

    def run(*argv, env: {}, chdir: nil, privileged: false, as_user: nil)
      command = argv.flatten.map(&:to_s)
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
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? do |directory|
        path = File.join(directory, name)
        File.file?(path) && File.executable?(path)
      end
    end

    private

    def privilege_prefix(as_user)
      if Process.euid.zero?
        return [] unless as_user
        runuser = %w[/usr/sbin/runuser /sbin/runuser /usr/bin/runuser].find { |path| File.executable?(path) }
        return [runuser, "-u", as_user, "--"] if runuser
        raise Error, "runuser is required to install as #{as_user}"
      end

      raise Error, "sudo is required for this installation mode" unless command?("sudo")
      as_user ? ["sudo", "-u", as_user, "--"] : ["sudo", "--"]
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
      unless @options.yes || @ui.confirm("Install Quarks with this configuration?")
        @ui.status(:warning, "Installation cancelled; nothing was changed.")
        return false
      end

      provision_user! if @options.mode == "managed"
      install!
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
      raise Error, "Missing project gemspec: #{GEMSPEC}" unless File.file?(GEMSPEC)
      missing = REQUIRED_COMMANDS.reject { |command| @runner.command?(command) }
      raise Error, "Missing required command(s): #{missing.join(', ')}" unless missing.empty?

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
      case @options.mode
      when "personal"
        home = Dir.home
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
      @ui.section("Installation plan")
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
      return if user_exists?(@options.user)
      @ui.section("Provisioning account")
      useradd = %w[/usr/sbin/useradd /sbin/useradd].find { |path| File.executable?(path) } || "useradd"
      @runner.run(
        useradd, "--create-home", "--home-dir", @options.home,
        "--shell", preferred_shell, "--comment", "Quarks package manager", @options.user,
        privileged: true
      )
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
        install_directories!
        install_gem!(artifact)
        write_launcher!
        verify_install!
      end
    end

    def install_directories!
      paths = [installed_path(@options.prefix), installed_path(@options.bindir)]
      if @runner.dry_run
        paths.each { |path| @ui.status(:step, "create directory #{path}") }
        return
      end

      if @options.mode == "managed"
        @runner.run("install", "-d", "-m", "0755", "-o", @options.user, "-g", primary_group, paths[0], privileged: true)
        @runner.run("install", "-d", "-m", "0755", paths[1], privileged: true)
      else
        paths.each { |path| FileUtils.mkdir_p(path, mode: 0o755) }
      end
    end

    def primary_group
      Etc.getpwnam(@options.user).gid.then { |gid| Etc.getgrgid(gid).name }
    rescue ArgumentError
      @options.user
    end

    def install_gem!(artifact)
      argv = ["gem", "install", "--no-document", "--install-dir", @options.prefix]
      argv << "--ignore-dependencies" unless @options.dependencies
      argv << artifact
      env = { "GEM_HOME" => @options.prefix }

      case @options.mode
      when "managed"
        env["HOME"] = @options.home
        @runner.run(*argv, env: env, privileged: true, as_user: @options.user)
      when "distribution"
        argv[argv.index(@options.prefix)] = installed_path(@options.prefix)
        env["GEM_HOME"] = installed_path(@options.prefix)
        @runner.run(*argv, env: env)
      else
        @runner.run(*argv, env: env)
      end
    end

    def write_launcher!
      target = installed_path(File.join(@options.bindir, "quarks"))
      content = launcher_content
      if @runner.dry_run
        @ui.status(:step, "write launcher #{target}")
        return
      end

      if @options.mode == "managed"
        Dir.mktmpdir("quarks-launcher-") do |directory|
          temporary = File.join(directory, "quarks")
          File.write(temporary, content, mode: "wb")
          File.chmod(0o755, temporary)
          @runner.run("install", "-m", "0755", temporary, target, privileged: true)
        end
      else
        temporary = "#{target}.tmp-#{Process.pid}"
        File.write(temporary, content, mode: "wb")
        File.chmod(0o755, temporary)
        File.rename(temporary, target)
      end
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def launcher_content
      <<~RUBY
        #!/usr/bin/env ruby
        # Generated by the Quarks bootstrap installer.
        require "rubygems"
        quarks_gem_home = #{@options.prefix.inspect}
        ENV["GEM_HOME"] = quarks_gem_home
        ENV["GEM_PATH"] = ([quarks_gem_home] + Gem.default_path).uniq.join(File::PATH_SEPARATOR)
        Gem.clear_paths
        load Gem.activate_bin_path("quarks-package-manager", "quarks", ">= 0.a")
      RUBY
    end

    def verify_install!
      return @ui.status(:success, "Dry run completed; no files were changed.") if @runner.dry_run

      launcher = installed_path(File.join(@options.bindir, "quarks"))
      env = { "GEM_HOME" => installed_path(@options.prefix) }
      if @options.mode == "managed"
        env["HOME"] = @options.home
        @runner.run(launcher, "version", env: env, privileged: true, as_user: @options.user)
      elsif @options.mode == "distribution"
        @ui.status(:success, "Staged launcher and gem payload successfully.")
      else
        @runner.run(launcher, "version", env: env)
      end
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
      case @options.mode
      when "personal"
        launcher = File.join(@options.bindir, "quarks")
        @ui.status(:success, "Quarks is installed at #{launcher}")
        unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).include?(@options.bindir)
          @ui.say "\n    Add this to your shell profile:"
          @ui.say "      export PATH=#{Shellwords.escape(@options.bindir)}:\"$PATH\""
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
      options = Options.new(color: nil, yes: false, dry_run: false)
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
