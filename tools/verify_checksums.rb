#!/usr/bin/env ruby
# frozen_string_literal: true
# part of dev tools
require "fileutils"
require "net/http"
require "uri"
require "digest"

class ChecksumVerifier
  def initialize(root, fix_mode)
    @root = root
    @fix_mode = fix_mode
    @nuclei_dir = File.join(root, "nuclei")
    @cache_dir = File.join(root, ".checksum_cache")
    @fixed = 0
    @verified = 0
    @errors = 0
    FileUtils.mkdir_p(@cache_dir)
  end

  def run
    unless File.directory?(@nuclei_dir)
      puts "Error: nuclei directory not found at #{@nuclei_dir}"
      exit 1
    end

    nuclei = Dir.glob(File.join(@nuclei_dir, "**", "*.nuclei")).sort

    nuclei.each do |file|
      verify_file(file)
    end

    puts "=" * 50
    puts "Results: #{@verified} verified, #{@fixed} fixed, #{@errors} errors"
    exit(@errors.positive? ? 1 : 0)
  end

  private

  def verify_file(file)
    text = File.read(file)
    pkg = text[/^\s*nuclei\s+"([^"]+)"/, 1] || File.basename(file, ".nuclei")
    modified = text

    sources = text.scan(/source\s+"([^"]+)"/).flatten
    checksums = text.scan(/checksum:\s*"([^"]+)"/).flatten
    algorithms = text.scan(/algorithm:\s*"([^"]+)"/).flatten

    sources.each_with_index do |url, idx|
      result = verify_source(pkg, url, checksums[idx], algorithms[idx] || "sha256")
      
      case result[:status]
      when :fixed
        modified = result[:modified]
        @fixed += 1
      when :verified
        @verified += 1
      when :error
        @errors += 1
      end
    end

    if @fix_mode && modified != text
      File.write(file, modified)
      puts "  -> Updated #{file}"
    end
  end

  def verify_source(pkg, url, expected, algorithm)
    uri = begin
      URI.parse(url)
    rescue
      puts "[error] #{pkg}: Invalid URL: #{url}"
      return { status: :error }
    end

    return { status: :skip } unless %w[http https].include?(uri.scheme)

    filename = File.basename(uri.path)
    cache_file = File.join(@cache_dir, filename)

    puts "Checking #{pkg}..."

    begin
      unless File.exist?(cache_file)
        puts "  Downloading #{filename}..."
        download_file(url, cache_file)
      end

      sha256 = Digest::SHA256.file(cache_file).hexdigest

      if expected.nil?
        puts "  [missing] No checksum defined for #{filename}"
        if @fix_mode
          modified = add_checksum(File.read(File.join(@nuclei_dir, "#{pkg}.nuclei")), url, sha256, algorithm)
          return { status: :fixed, modified: modified }
        end
      elsif expected == "skip"
        puts "  [placeholder] #{filename}"
        puts "    would be: #{sha256}"
        if @fix_mode
          modified = update_checksum(File.read(File.join(@nuclei_dir, "#{pkg}.nuclei")), url, sha256, algorithm)
          return { status: :fixed, modified: modified }
        end
      elsif expected != sha256
        puts "  [mismatch] #{filename}"
        puts "    expected: #{expected}"
        puts "    actual:   #{sha256}"
        if @fix_mode
          modified = update_checksum(File.read(File.join(@nuclei_dir, "#{pkg}.nuclei")), url, sha256, algorithm)
          return { status: :fixed, modified: modified }
        end
      else
        puts "  [ok] Checksum verified"
        return { status: :verified }
      end
    rescue => e
      puts "  [error] #{e.class}: #{e.message}"
      return { status: :error }
    end

    { status: :checked }
  end

  def download_file(url, cache_file)
    uri = URI.parse(url)
    max_redirects = 5

    max_redirects.times do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 60
      http.read_timeout = 300

      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = "Quarks/1.0"

      res = http.request(req) do |response|
        case response
        when Net::HTTPSuccess
          File.open(cache_file, "wb") do |f|
            response.read_body do |chunk|
              f.write(chunk)
            end
          end
          return true
        when Net::HTTPRedirection
          location = response["location"]
          puts "    -> Following redirect to #{location}"
          uri = URI.parse(location)
        else
          raise "HTTP #{response.code} #{response.message}"
        end
      end
    end

    raise "Too many redirects"
  end

  def add_checksum(text, url, sha256, algorithm)
    pattern = /source\s+"#{Regexp.escape(url)}"/
    replacement = "source \"#{url}\",\n         checksum: \"#{sha256}\",\n         algorithm: \"#{algorithm}\""
    text.gsub(pattern, replacement)
  end

  def update_checksum(text, url, sha256, algorithm)
    lines = text.lines
    result = []
    i = 0

    while i < lines.length
      line = lines[i]
      if line =~ /source\s+"#{Regexp.escape(url)}"/
        result << line
        i += 1
        while i < lines.length && lines[i] =~ /^\s+checksum:/
          i += 1
        end
        while i < lines.length && lines[i] =~ /^\s+algorithm:/
          i += 1
        end
        result << "         checksum: \"#{sha256}\",\n"
        result << "         algorithm: \"#{algorithm}\"\n"
      else
        result << line
        i += 1
      end
    end

    result.join
  end
end

if __FILE__ == $PROGRAM_NAME
  root = ARGV[0] || File.dirname(File.dirname(__FILE__))
  fix_mode = ARGV.include?("--fix")
  
  ChecksumVerifier.new(root, fix_mode).run
end
