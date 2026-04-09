#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "pathname"
require "time"

class Doctor
  Issue = Struct.new(:severity, :title, :details, :hint, keyword_init: true)
  SEVERITY_ORDER = { ok: 0, info: 1, warn: 2, fail: 3 }.freeze

  def initialize
    @issues = []
    @start = Time.now
    @cwd = Pathname.pwd
    @repo_root = find_repo_root(@cwd)
  end

  def run
    banner
    check_repo_root
    check_ruby
    check_tools
    check_entrypoint
    check_repository
    check_database
    summarize
    exit(exit_code)
  end

  private

  def add(severity:, title:, details: nil, hint: nil)
    @issues << Issue.new(severity: severity, title: title, details: details, hint: hint)
  end

  def banner
    puts "Quarks Doctor — wsg gng :D"
    puts "cwd: #{@cwd}"
    puts "repo_root: #{@repo_root || '(not found)'}"
    puts "QUARKS_ROOT=#{ENV['QUARKS_ROOT'] || '(unset)'}"
    puts "QUARKS_STATE_ROOT=#{ENV['QUARKS_STATE_ROOT'] || '(unset)'}"
    puts "QUARKS_REPO_URLS=#{ENV['QUARKS_REPO_URLS'] || '(unset)'}"
    puts "-" * 72
  end

  def find_repo_root(start)
    cur = start
    15.times do
      return cur if (cur / "src" / "quarks").directory?
      parent = cur.parent
      break if parent == cur
      cur = parent
    end
    nil
  end

  def check_repo_root
    if @repo_root
      add(severity: :ok, title: "Repo root detected", details: @repo_root.to_s)
    else
      add(severity: :fail, title: "Not inside a Quarks repo", hint: "Run this from the Quarks repo root so src/quarks is visible.")
    end
  end

  def check_ruby
    out, status = Open3.capture2("ruby", "-v")
    if status.success?
      add(severity: :ok, title: "Ruby OK", details: out.strip)
    else
      add(severity: :fail, title: "Ruby not runnable", hint: "Install Ruby and ensure it is on PATH.")
    end
  rescue => e
    add(severity: :fail, title: "Ruby check crashed", details: e.message)
  end

  def check_tools
    %w[gcc make tar git curl sqlite3 patch].each do |tool|
      path = which(tool)
      if path
        add(severity: :ok, title: "#{tool} OK", details: path)
      else
        add(severity: :warn, title: "#{tool} missing", hint: "Install #{tool}; some packages or checks will fail.")
      end
    end
  end

  def check_entrypoint
    return unless @repo_root

    entry = @repo_root / "quarks"
    unless entry.file?
      add(severity: :fail, title: "Missing ./quarks entrypoint")
      return
    end

    if entry.executable?
      add(severity: :ok, title: "./quarks executable")
    else
      add(severity: :warn, title: "./quarks is not executable", hint: "chmod +x quarks")
    end
  end

  def check_repository
    return unless @repo_root

    begin
      $LOAD_PATH.unshift((@repo_root / "src").to_s)
      require "quarks/env"
      require "quarks/package"
      require "quarks/repository"

      repo = Quarks::Repository.new(@repo_root / "nuclei")
      atoms = repo.list_atoms

      if atoms.empty?
        add(
          severity: :warn,
          title: "Repository indexes 0 packages",
          details: (repo.errors + repo.warnings).join("\n"),
          hint: "Check nuclei syntax, repo layout, and QUARKS_NUCLEI_PATHS / QUARKS_REPO_URLS."
        )
      else
        add(severity: :ok, title: "Repository indexes #{atoms.length} package(s)")
      end

      repo.warnings.each { |warn_msg| add(severity: :warn, title: "Repository warning", details: warn_msg) }
      repo.errors.each { |err_msg| add(severity: :fail, title: "Repository error", details: err_msg) }
    rescue LoadError => e
      add(severity: :fail, title: "Could not load Quarks repository code", details: e.message)
    rescue => e
      add(severity: :fail, title: "Repository check crashed", details: "#{e.class}: #{e.message}")
    end
  end

  def check_database
    return unless @repo_root

    begin
      $LOAD_PATH.unshift((@repo_root / "src").to_s)
      require "quarks/database"
      db_path = Quarks::Database::DB_PATH

      if File.exist?(db_path)
        add(severity: :ok, title: "Database file exists", details: db_path)
      else
        add(severity: :warn, title: "Database file missing", details: db_path, hint: "Run Quarks once to initialize the DB.")
      end
    rescue LoadError => e
      add(severity: :warn, title: "Could not load Quarks database code", details: e.message)
    rescue => e
      add(severity: :warn, title: "Database check crashed", details: "#{e.class}: #{e.message}")
    end
  end

  def summarize
    puts "-" * 72
    counts = @issues.group_by(&:severity).transform_values(&:size)
    puts "Summary: ok=#{counts[:ok].to_i} info=#{counts[:info].to_i} warn=#{counts[:warn].to_i} fail=#{counts[:fail].to_i}"
    puts

    @issues.sort_by { |issue| -SEVERITY_ORDER.fetch(issue.severity, 99) }.each do |issue|
      icon = case issue.severity
             when :ok then "[ok]"
             when :info then "[..]"
             when :warn then "[!!]"
             else "[XX]"
             end

      puts "#{icon} #{issue.title}"
      puts "     #{issue.details.gsub("\n", "\n     ")}" if issue.details && !issue.details.empty?
      puts "     hint: #{issue.hint.gsub("\n", "\n           ")}" if issue.hint && !issue.hint.empty?
    end

    puts
    puts "Done in #{((Time.now - @start) * 1000).round}ms"
  end

  def exit_code
    @issues.any? { |issue| issue.severity == :fail } ? 1 : 0
  end

  def which(cmd)
    out, status = Open3.capture2("bash", "-lc", "command -v #{cmd}")
    status.success? ? out.strip : nil
  end
end

Doctor.new.run
