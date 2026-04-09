#!/usr/bin/env ruby
# frozen_string_literal: true

require "uri"
require "net/http"
require "openssl"
require "digest"
require "open3"

class RepoAudit
  Issue = Struct.new(:severity, :file, :message, keyword_init: true)

  VALID_BUILD_SYSTEMS = %w[
    auto meson cmake autotools make ninja manual
  ].freeze

  attr_reader :issues

  def initialize(root_dir)
    @root_dir = File.expand_path(root_dir)
    @nuclei_dir = File.join(@root_dir, "nuclei")
    @issues = []
    @packages_by_name = {}
    @packages_by_atom = {}
  end

  def run
    unless Dir.exist?(@nuclei_dir)
      puts "No nuclei directory found at #{@nuclei_dir}"
      exit 1
    end

    files = Dir.glob(File.join(@nuclei_dir, "**", "*.nuclei")).sort
    if files.empty?
      puts "No .nuclei files found under #{@nuclei_dir}"
      exit 1
    end

    files.each { |file| inspect_file(file) }

    print_report
    exit(exit_code)
  end

  private

  def inspect_file(file)
    text = File.read(file)
    first_decl = first_nuclei_decl(text)

    unless first_decl
      add(:fail, file, "missing nuclei declaration")
      return
    end

    pkg_name = first_decl[:name]
    version  = first_decl[:version]
    category = extract_call_arg(text, "category")
    build_system = extract_build_system(text)
    sources = extract_sources(text)
    has_build_block = !!(text =~ /^\s*build\s+do\b/m)

    filebase = File.basename(file, ".nuclei")
    if pkg_name != filebase
      add(:warn, file, "declares #{pkg_name.inspect}, filename suggests #{filebase.inspect}")
    end

    atom = [category, pkg_name].compact.join("/")

    if @packages_by_name.key?(pkg_name)
      add(:fail, file, "duplicate package name #{pkg_name.inspect}; already defined in #{@packages_by_name[pkg_name]}")
    else
      @packages_by_name[pkg_name] = rel(file)
    end

    if !category.to_s.empty?
      if @packages_by_atom.key?(atom)
        add(:fail, file, "duplicate package atom #{atom.inspect}; already defined in #{@packages_by_atom[atom]}")
      else
        @packages_by_atom[atom] = rel(file)
      end
    else
      add(:warn, file, "missing category")
    end

    add(:warn, file, "missing description") unless extract_call_arg(text, "description")
    add(:warn, file, "missing homepage") unless extract_call_arg(text, "homepage")
    add(:warn, file, "missing license") unless extract_call_arg(text, "license")
    add(:warn, file, "missing build block") unless has_build_block
    add(:warn, file, "missing version") if version.to_s.strip.empty?

    if build_system
      unless VALID_BUILD_SYSTEMS.include?(build_system)
        add(:fail, file, "invalid build_system #{build_system.inspect}")
      end
    else
      add(:warn, file, "missing build_system declaration")
    end

    if sources.empty?
      add(:fail, file, "no source entries found")
    else
      sources.each_with_index do |src, idx|
        audit_source(file, src, idx)
      end
    end
  rescue => e
    add(:fail, file, "audit crashed: #{e.class}: #{e.message}")
  end

  def audit_source(file, src, idx)
    url = src[:url]
    checksum = src[:checksum]
    algorithm = src[:algorithm]

    if url.nil? || url.empty?
      add(:fail, file, "source ##{idx + 1}: missing URL")
      return
    end

    begin
      uri = URI.parse(url)
      unless %w[http https file].include?(uri.scheme)
        add(:warn, file, "source ##{idx + 1}: unusual scheme #{uri.scheme.inspect} for #{url}")
      end
    rescue URI::InvalidURIError
      add(:fail, file, "source ##{idx + 1}: invalid URL #{url.inspect}")
      return
    end

    if checksum.nil? || checksum.empty?
      add(:warn, file, "source ##{idx + 1}: missing checksum")
    elsif checksum == "skip"
      add(:warn, file, "source ##{idx + 1}: insecure checksum skip for #{url}")
    else
      unless checksum.match?(/\A[0-9a-fA-F]+\z/)
        add(:fail, file, "source ##{idx + 1}: checksum is not valid hex")
      end

      if algorithm.to_s.empty?
        add(:warn, file, "source ##{idx + 1}: missing checksum algorithm")
      end
    end

    return unless %w[http https].include?(URI.parse(url).scheme)

    status = http_check(url)
    case status[:status]
    when :ok
      # all good
    when :redirect
      add(:info, file, "source ##{idx + 1}: redirects #{url} -> #{status[:location]}")
    when :http_error
      add(:fail, file, "source ##{idx + 1}: HTTP #{status[:code]} #{status[:message]} for #{url}")
    when :network_error
      add(:fail, file, "source ##{idx + 1}: network error for #{url}: #{status[:message]}")
    end
  end

  def http_check(url)
    uri = URI.parse(url)

    Net::HTTP.start(
      uri.host,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 8,
      read_timeout: 12,
      ssl_timeout: 8
    ) do |http|
      request = Net::HTTP::Head.new(uri)
      request["User-Agent"] = "QuarksRepoAudit/1.0"

      response = http.request(request)

      case response
      when Net::HTTPSuccess
        { status: :ok }
      when Net::HTTPRedirection
        { status: :redirect, location: response["location"] }
      else
        { status: :http_error, code: response.code, message: response.message }
      end
    end
  rescue => e
    { status: :network_error, message: "#{e.class}: #{e.message}" }
  end

  def first_nuclei_decl(text)
    line = text.each_line.find { |l| l =~ /^\s*nuclei\s+"([^"]+)"\s*,\s*"([^"]+)"/ }
    return nil unless line

    {
      name: line[/^\s*nuclei\s+"([^"]+)"/, 1],
      version: line[/^\s*nuclei\s+"[^"]+"\s*,\s*"([^"]+)"/, 1]
    }
  end

  def extract_call_arg(text, method_name)
    line = text.each_line.find { |l| l =~ /^\s*#{Regexp.escape(method_name)}\s+"([^"]+)"/ }
    return nil unless line
    line[/^\s*#{Regexp.escape(method_name)}\s+"([^"]+)"/, 1]
  end

  def extract_build_system(text)
    line = text.each_line.find { |l| l =~ /^\s*build_system\s+:([a-zA-Z0-9_]+)/ }
    return nil unless line
    line[/^\s*build_system\s+:([a-zA-Z0-9_]+)/, 1]
  end

  def extract_sources(text)
    sources = []

    text.scan(/source\s+"([^"]+)"(.*?)(?=^\s*\w|\z)/m).each do |url, tail|
      checksum =
        tail[/checksum:\s*"([^"]+)"/, 1] ||
        tail[/sha256:\s*"([^"]+)"/, 1] ||
        tail[/sha512:\s*"([^"]+)"/, 1] ||
        tail[/md5:\s*"([^"]+)"/, 1]

      algorithm =
        if tail[/sha256:\s*"([^"]+)"/, 1]
          "sha256"
        elsif tail[/sha512:\s*"([^"]+)"/, 1]
          "sha512"
        elsif tail[/md5:\s*"([^"]+)"/, 1]
          "md5"
        else
          tail[/algorithm:\s*"([^"]+)"/, 1]
        end

      sources << {
        url: url,
        checksum: checksum,
        algorithm: algorithm
      }
    end

    sources
  end

  def add(severity, file, message)
    @issues << Issue.new(severity: severity, file: rel(file), message: message)
  end

  def rel(path)
    path.sub(@root_dir + "/", "")
  end

  def print_report
    grouped = @issues.group_by(&:severity)
    counts = {
      fail: grouped.fetch(:fail, []).size,
      warn: grouped.fetch(:warn, []).size,
      info: grouped.fetch(:info, []).size
    }

    puts "Quarks Repo Audit"
    puts "-" * 72
    puts "root: #{@root_dir}"
    puts "nuclei: #{@nuclei_dir}"
    puts "-" * 72
    puts "Summary: fail=#{counts[:fail]} warn=#{counts[:warn]} info=#{counts[:info]}"
    puts

    order = { fail: 0, warn: 1, info: 2 }

    @issues.sort_by { |i| [order.fetch(i.severity, 99), i.file, i.message] }.each do |issue|
      icon =
        case issue.severity
        when :fail then "[XX]"
        when :warn then "[!!]"
        else "[..]"
        end

      puts "#{icon} #{issue.file}"
      puts "     #{issue.message}"
    end

    puts if @issues.any?
    puts "No issues found. Repo looks clean :D" if @issues.empty?
  end

  def exit_code
    @issues.any? { |i| i.severity == :fail } ? 1 : 0
  end
end

if __FILE__ == $PROGRAM_NAME
  root = ARGV[0] || Dir.pwd
  RepoAudit.new(root).run
end