#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "net/http"
require "uri"
require "digest"

root = ARGV[0] || Dir.pwd
nuclei = Dir.glob(File.join(root, "nuclei", "**", "*.nuclei")).sort
cache_dir = File.join(root, ".repo_audit_cache")
FileUtils.mkdir_p(cache_dir)

nuclei.each do |file|
  text = File.read(file)
  pkg = text[/^\s*nuclei\s+"([^"]+)"/, 1] || File.basename(file, ".nuclei")

  text.scan(/source\s+"([^"]+)"/).flatten.each do |url|
    begin
      uri = URI.parse(url)
      next unless %w[http https].include?(uri.scheme)

      filename = File.basename(uri.path)
      filename = "#{pkg}.src" if filename.nil? || filename.empty?
      local = File.join(cache_dir, filename)

      unless File.exist?(local)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          req = Net::HTTP::Get.new(uri)
          req["User-Agent"] = "QuarksChecksumHelper/1.0"
          res = http.request(req)
          raise "HTTP #{res.code} #{res.message}" unless res.is_a?(Net::HTTPSuccess)
          File.binwrite(local, res.body)
        end
      end

      sha256 = Digest::SHA256.file(local).hexdigest
      puts "#{file}:"
      puts "  source #{url}"
      puts "  sha256 #{sha256}"
      puts
    rescue => e
      puts "#{file}:"
      puts "  source #{url}"
      puts "  ERROR #{e.class}: #{e.message}"
      puts
    end
  end
end