# frozen_string_literal: true

require "digest"
require "uri"
require "quarks/env"
require "quarks/hash_verifier"

module Quarks
  class SourceSize
    Result = Struct.new(
      :total_bytes, :download_bytes, :cached_bytes, :unknown_sources,
      keyword_init: true
    ) do
      def exact? = unknown_sources.zero?
      def cached? = cached_bytes.positive?
    end

    def initialize(state_root: Quarks::Env.state_root)
      @cache_dir = File.join(state_root, "var", "cache", "quarks", "distfiles")
      @verification_cache = {}
    end

    def measure(package)
      result = Result.new(total_bytes: 0, download_bytes: 0, cached_bytes: 0, unknown_sources: 0)

      Array(package.sources).each_with_index do |source, index|
        source = source.to_s
        local_path = local_source_path(source)
        cached_path = local_path || cache_path(source, index)

        if valid_source_file?(cached_path, package, source)
          bytes = File.size(cached_path)
          result.total_bytes += bytes
          result.cached_bytes += bytes
          next
        end

        declared = declared_size(package, source)
        if declared
          result.total_bytes += declared
          result.download_bytes += declared unless local_path
        else
          result.unknown_sources += 1
        end
      end

      result
    end

    def measure_all(packages)
      Array(packages).map { |package| measure(package) }.reduce(
        Result.new(total_bytes: 0, download_bytes: 0, cached_bytes: 0, unknown_sources: 0)
      ) do |total, result|
        total.total_bytes += result.total_bytes
        total.download_bytes += result.download_bytes
        total.cached_bytes += result.cached_bytes
        total.unknown_sources += result.unknown_sources
        total
      end
    end

    def cache_path(source, index)
      uri = URI.parse(source.to_s)
      File.join(@cache_dir, self.class.cache_filename(uri, index))
    rescue URI::InvalidURIError
      File.join(@cache_dir, "invalid-source-#{index + 1}")
    end

    def self.cache_filename(uri, index)
      base = File.basename(uri.path.to_s)
      base = "source-#{index + 1}" if base.nil? || base.empty? || base == "/"
      digest = Digest::SHA256.hexdigest(uri.to_s)[0, 16]
      "#{digest}-#{base.gsub(/[^a-zA-Z0-9._-]/, '_')}"
    end

    private

    def local_source_path(source)
      return unless source.start_with?("file://")

      path = File.expand_path(URI.parse(source).path)
      path if File.file?(path)
    rescue URI::InvalidURIError
      nil
    end

    def declared_size(package, source)
      raw = package.source_sizes[source] || package.source_sizes[source.to_s]
      size = Integer(raw, exception: false)
      size if size&.positive?
    end

    def valid_source_file?(path, package, source)
      return false unless path && File.file?(path)

      stat = File.stat(path)
      declared = declared_size(package, source)
      return false if declared && stat.size != declared

      checksum = package.checksums[source] || package.checksums[source.to_s]
      return false unless checksum.is_a?(Hash)

      algorithm = checksum[:algorithm] || checksum["algorithm"] || "sha256"
      expected = checksum[:hash] || checksum["hash"]
      cache_key = [path, stat.size, stat.mtime.to_f, algorithm.to_s, expected.to_s]
      @verification_cache.fetch(cache_key) do
        @verification_cache[cache_key] = Quarks::HashVerifier.verify_file(
          path,
          algorithm: algorithm,
          expected_hex: expected
        )
      end
    rescue SystemCallError, Quarks::HashVerifier::VerificationError
      false
    end
  end
end
