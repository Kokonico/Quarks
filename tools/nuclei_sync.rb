#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "fileutils"
require "net/http"
require "uri"
require "digest"
require "optparse"

class NucleiSync
  DEFAULT_REPOS = {
    "main" => {
      url: "https://RobertFlexx.github.io/Photon/docs",
      mirrors: [
        "https://mirror.ghproxy.com/https://RobertFlexx.github.io/Photon/docs"
      ]
    }
  }.freeze

  def initialize
    @options = {
      repo: "main",
      force: false,
      dry_run: false,
      verify: true,
      verbose: false,
      only_package: nil
    }
    @nuclei_dir = File.join(File.dirname(__FILE__), "..", "nuclei")
    @state_dir = File.join(File.dirname(__FILE__), "..", "var", "cache", "photon", "repo_sync")
  end

  def run
    parse_options!

    FileUtils.mkdir_p(@nuclei_dir)
    FileUtils.mkdir_p(@state_dir)

    repo_config = DEFAULT_REPOS[@options[:repo]] || DEFAULT_REPOS["main"]

    puts "Syncing nuclei recipes from #{repo_config[:url]}..."

    index = fetch_index(repo_config)
    if index.nil?
      puts "[error] Failed to fetch repository index"
      exit 1
    end

    packages = index["packages"] || []
    puts "Found #{packages.length} packages in repository"

    synced = 0
    skipped = 0
    errors = 0

    packages.each do |pkg|
      next if @options[:only_package] && pkg["atom"] != @options[:only_package]

      result = sync_package(pkg, repo_config)
      case result
      when :synced
        synced += 1
      when :skipped
        skipped += 1
      when :error
        errors += 1
      end
    end

    save_sync_state(@options[:repo], packages)

    puts
    puts "Sync complete: #{synced} synced, #{skipped} skipped, #{errors} errors"
    exit(errors > 0 ? 1 : 0)
  end

  private

  def parse_options!
    OptionParser.new do |opts|
      opts.banner = "Usage: #{File.basename(__FILE__)} [options]"

      opts.on("-r", "--repo NAME", "Repository name (default: main)") do |v|
        @options[:repo] = v
      end

      opts.on("-f", "--force", "Force re-download even if unchanged") do
        @options[:force] = true
      end

      opts.on("-n", "--dry-run", "Show what would be done without making changes") do
        @options[:dry_run] = true
      end

      opts.on("-p", "--package ATOM", "Only sync specific package") do |v|
        @options[:only_package] = v
      end

      opts.on("-v", "--verbose", "Verbose output") do
        @options[:verbose] = true
      end

      opts.on("-h", "--help", "Show this help") do
        puts opts
        exit
      end
    end.parse!
  end

  def fetch_index(repo_config)
    url = "#{repo_config[:url]}/index.json"
    urls_to_try = [url] + (repo_config[:mirrors] || []).map { |m| "#{m}/index.json" }

    urls_to_try.each do |try_url|
      begin
        debug "Trying #{try_url}"
        uri = URI.parse(try_url)
        response = http_get(uri)

        if response.is_a?(Net::HTTPSuccess)
          return JSON.parse(response.body)
        end
      rescue => e
        debug "Failed: #{e.message}"
      end
    end

    load_cached_index
  end

  def load_cached_index
    cache_path = File.join(@state_dir, "#{@options[:repo]}_index.json")
    return nil unless File.exist?(cache_path)

    debug "Using cached index"
    JSON.parse(File.read(cache_path))
  end

  def save_sync_state(repo_name, packages)
    cache_path = File.join(@state_dir, "#{repo_name}_index.json")
    File.write(cache_path, JSON.pretty_generate({
      "synced_at" => Time.now.iso8601,
      "packages" => packages
    }))
  end

  def sync_package(pkg, repo_config)
    atom = pkg["atom"]
    recipe_relpath = pkg["recipe_relpath"]

    return :skipped if recipe_relpath.nil?

    local_path = File.join(@nuclei_dir, File.basename(recipe_relpath))

    if !@options[:force] && File.exist?(local_path)
      cached_hash = Digest::SHA256.file(local_path).hexdigest
      remote_hash = pkg["recipe_sha256"]

      if cached_hash == remote_hash
        debug "Skipping #{atom} (unchanged)"
        return :skipped
      end
    end

    recipe_url = "#{repo_config[:url]}/#{recipe_relpath}"

    urls_to_try = [recipe_url] + (repo_config[:mirrors] || []).map { |m| "#{m}/#{recipe_relpath}" }

    urls_to_try.each do |try_url|
      begin
        debug "Fetching #{try_url}"
        content = fetch_recipe(try_url)

        if content
          if @options[:dry_run]
            puts "[dry-run] Would update #{atom}"
            return :synced
          else
            File.write(local_path, content)
            puts "[ok] #{atom}" + (@options[:verbose] ? " -> #{File.basename(recipe_relpath)}" : "")
            return :synced
          end
        end
      rescue => e
        debug "Failed fetching #{try_url}: #{e.message}"
      end
    end

    puts "[error] Failed to fetch recipe for #{atom}"
    :error
  rescue => e
    puts "[error] #{atom}: #{e.message}"
    :error
  end

  def fetch_recipe(url)
    uri = URI.parse(url)
    response = http_get(uri)

    return nil unless response.is_a?(Net::HTTPSuccess)

    content = response.body

    if @options[:verify]
      checksum_url = "#{url}.sha256"
      begin
        checksum_response = http_get(URI.parse(checksum_url))
        if checksum_response.is_a?(Net::HTTPSuccess)
          expected = checksum_response.body.strip.split.first
          actual = Digest::SHA256.hexdigest(content)
          unless actual == expected
            warn "Checksum mismatch for #{url}"
            return nil
          end
        end
      rescue
      end
    end

    content
  end

  def http_get(uri, timeout: 30)
    redirects = 0
    max_redirects = 5

    loop do
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = 10
      http.read_timeout = timeout

      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Photon-NucleiSync/1.0"
      request["Accept-Encoding"] = "gzip, deflate"

      begin
        response = http.request(request)

        case response
        when Net::HTTPSuccess
          return response.body
        when Net::HTTPRedirection
          raise "Too many redirects" if redirects >= max_redirects
          uri = URI.parse(response["location"])
          redirects += 1
        else
          return nil
        end
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        debug "Timeout: #{e.message}"
        return nil
      rescue SocketError, Errno::ECONNRESET, Errno::ECONNREFUSED => e
        debug "Connection error: #{e.message}"
        return nil
      end
    end
  end

  def debug(msg)
    puts "  [debug] #{msg}" if @options[:verbose]
  end

  def warn(msg)
    puts "  [warn] #{msg}"
  end
end

if __FILE__ == $PROGRAM_NAME
  NucleiSync.new.run
end
