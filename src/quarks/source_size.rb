# frozen_string_literal: true

require "digest"
require "json"
require "net/http"
require "openssl"
require "thread"
require "uri"
require "quarks/env"
require "quarks/hash_verifier"
require "quarks/security"

module Quarks
  class SourceSize
    Result = Struct.new(
      :total_bytes, :download_bytes, :cached_bytes, :unknown_sources,
      keyword_init: true
    ) do
      def exact? = unknown_sources.zero?
      def cached? = cached_bytes.positive?
    end

    ProbeResult = Struct.new(:bytes, :definitive, keyword_init: true)

    MAX_REDIRECTS = 5
    PROBE_WORKERS = 8
    PROBE_BUDGET_SECONDS = 0.6
    PROBE_CONNECT_TIMEOUT = 0.35
    PROBE_READ_TIMEOUT = 0.45
    CACHE_MAX_BYTES = 4 * 1024 * 1024
    NEGATIVE_CACHE_TTL = 300
    ADVISORY_CACHE_TTL = 6 * 60 * 60
    CACHE_WRITE_MUTEX = Mutex.new

    def initialize(state_root: Quarks::Env.state_root)
      @cache_dir = File.join(state_root, "var", "cache", "quarks", "distfiles")
      @size_cache_path = File.join(state_root, "var", "cache", "quarks", "source-sizes.json")
      @verification_cache = {}
      @size_cache = load_size_cache
      @size_cache_mutex = Mutex.new
      @size_cache_dirty = {}
    end

    def measure(package, remote_sizes: nil)
      result = empty_result

      Array(package.sources).each_with_index do |raw_source, index|
        source = raw_source.to_s
        local_path = local_source_path(source)
        cached_path = local_path || cache_path(source, index)
        cached_bytes = cached_source_bytes(cached_path, package, source)

        if cached_bytes
          result.total_bytes += cached_bytes
          result.cached_bytes += cached_bytes
          next
        end

        declared = declared_size(package, source) || remote_sizes&.[](source)
        if declared
          result.total_bytes += declared
          result.download_bytes += declared unless local_path
        else
          result.unknown_sources += 1
        end
      end

      result
    end

    def measure_many(packages, probe_remote: false)
      packages = Array(packages)
      remote_sizes = probe_remote ? resolve_remote_sizes(packages) : {}
      packages.to_h { |package| [package.atom, measure(package, remote_sizes: remote_sizes)] }
    ensure
      persist_size_cache if size_cache_dirty?
    end

    def measure_all(packages, probe_remote: false)
      measure_many(packages, probe_remote: probe_remote).values.reduce(empty_result) do |total, result|
        total.total_bytes += result.total_bytes
        total.download_bytes += result.download_bytes
        total.cached_bytes += result.cached_bytes
        total.unknown_sources += result.unknown_sources
        total
      end
    end

    def record_verified(package, source, bytes, path: nil)
      value = Integer(bytes, exception: false)
      return false unless value&.positive?

      key = size_cache_key(package, source.to_s)
      stamp = path ? file_stamp(path) : nil
      changed = @size_cache_mutex.synchronize do
        current = @size_cache[key]
        current_bytes = current.is_a?(Hash) ? Integer(current["bytes"], exception: false) : Integer(current, exception: false)
        current_stamp = current.is_a?(Hash) ? normalize_verified_stamp(current["verified_file"]) : nil
        current_verified = current.is_a?(Hash) && current["verified"] == true
        next false if current_bytes == value && current_verified && (!stamp || current_stamp == stamp)

        entry = { "bytes" => value, "checked_at" => Time.now.to_i, "verified" => true }
        entry["verified_file"] = stamp if stamp
        @size_cache[key] = entry
        @size_cache_dirty[key] = entry
        true
      end
      persist_size_cache if changed
      true
    rescue SystemCallError, SecurityViolation
      false
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

    def empty_result
      Result.new(total_bytes: 0, download_bytes: 0, cached_bytes: 0, unknown_sources: 0)
    end

    def resolve_remote_sizes(packages)
      records = []
      sizes = {}
      packages.each do |package|
        Array(package.sources).each_with_index do |raw_source, index|
          source = raw_source.to_s
          next if local_source_path(source)
          next if declared_size(package, source)
          next unless remote_source?(source)

          cached_path = cache_path(source, index)
          next if cached_source_bytes(cached_path, package, source)

          key = size_cache_key(package, source)
          if (bytes = cached_remote_size(key))
            sizes[source] = bytes
            next
          end
          next if negative_cached?(key)

          records << [source, key]
        end
      end
      return sizes if records.empty?

      grouped = {}
      records.each do |source, key|
        keys = (grouped[source] ||= {})
        keys[key] = true
      end

      discovered = {}
      definitive_unknown = []
      queue = Queue.new
      grouped.each_key { |source| queue << source }
      mutex = Mutex.new
      deadline = Security.monotonic_time + probe_budget_seconds
      worker_count = [[PROBE_WORKERS, grouped.length].min, 1].max
      workers = worker_count.times.map do
        Thread.new do
          Thread.current.report_on_exception = false
          loop do
            break if Security.monotonic_time >= deadline
            source = queue.pop(true)
            result = probe_remote_size(source, deadline: deadline)
            mutex.synchronize do
              if result.bytes
                discovered[source] = result.bytes
              elsif result.definitive
                definitive_unknown << source
              end
            end
          rescue ThreadError
            break
          rescue
            next
          end
        end
      end

      workers.each do |worker|
        remaining = deadline - Security.monotonic_time
        break if remaining <= 0
        worker.join(remaining)
      end
      workers.each(&:kill)
      workers.each { |worker| worker.join(0.05) }

      now = Time.now.to_i
      discovered.each do |source, bytes|
        sizes[source] = bytes
        grouped[source].each_key { |key| store_cache_entry(key, bytes: bytes, checked_at: now, verified: false) }
      end
      definitive_unknown.uniq.each do |source|
        grouped[source].each_key { |key| store_cache_entry(key, unknown_until: now + NEGATIVE_CACHE_TTL, checked_at: now) }
      end
      sizes
    end

    def remote_source?(source)
      uri = URI.parse(source)
      uri.is_a?(URI::HTTP) && uri.host && !uri.host.empty?
    rescue URI::InvalidURIError
      false
    end

    def probe_budget_seconds
      milliseconds = Integer(ENV["QUARKS_SIZE_PROBE_MS"].to_s, exception: false)
      return PROBE_BUDGET_SECONDS unless milliseconds
      [[milliseconds, 0].max, 5_000].min / 1000.0
    end

    def size_cache_key(package, source)
      checksum = package.checksums[source] || package.checksums[source.to_s]
      algorithm = checksum.is_a?(Hash) ? (checksum[:algorithm] || checksum["algorithm"] || "sha256") : ""
      expected = checksum.is_a?(Hash) ? (checksum[:hash] || checksum["hash"]) : ""
      Digest::SHA256.hexdigest([source, algorithm.to_s.downcase, expected.to_s.downcase].join("\0"))
    end

    def cached_remote_size(key)
      entry = @size_cache_mutex.synchronize { @size_cache[key] }
      return unless entry.is_a?(Hash)

      bytes = Integer(entry["bytes"], exception: false)
      return unless bytes&.positive?
      return bytes if entry["verified"] == true

      checked_at = Integer(entry["checked_at"], exception: false)
      bytes if checked_at && checked_at >= Time.now.to_i - ADVISORY_CACHE_TTL
    end

    def negative_cached?(key)
      entry = @size_cache_mutex.synchronize { @size_cache[key] }
      return false unless entry.is_a?(Hash)
      expires = Integer(entry["unknown_until"], exception: false)
      expires && expires > Time.now.to_i
    end

    def store_cache_entry(key, values)
      @size_cache_mutex.synchronize do
        current = @size_cache[key]
        current = { "bytes" => current } if Integer(current, exception: false)&.positive?
        current = current.is_a?(Hash) ? current.dup : {}
        updates = values.transform_keys(&:to_s)
        if updates.key?("bytes")
          current.delete("unknown_until")
        elsif updates.key?("unknown_until")
          current.delete("bytes")
          current.delete("verified")
          current.delete("verified_file")
        end
        entry = current.merge(updates)
        @size_cache[key] = entry
        @size_cache_dirty[key] = entry
      end
    end

    def probe_remote_size(source, deadline:)
      allow_http = ENV["QUARKS_ALLOW_INSECURE_SOURCES"] == "1"
      allow_private = ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] == "1"
      uri = Security.validate_remote_uri!(
        source,
        purpose: "package source size",
        allow_http: allow_http,
        allow_private: allow_private,
        resolve: false
      )

      redirects = 0
      while redirects <= MAX_REDIRECTS && Security.monotonic_time < deadline
        range = probe_request(uri, allow_private: allow_private, method: :range, deadline: deadline)
        if range[:redirect]
          uri = validate_redirect(uri, range[:redirect], allow_http: allow_http, allow_private: allow_private)
          redirects += 1
          next
        end
        return ProbeResult.new(bytes: range[:size], definitive: true) if range[:size]

        head = probe_request(uri, allow_private: allow_private, method: :head, deadline: deadline)
        if head[:redirect]
          uri = validate_redirect(uri, head[:redirect], allow_http: allow_http, allow_private: allow_private)
          redirects += 1
          next
        end
        return ProbeResult.new(bytes: head[:size], definitive: true) if head[:size]
        return ProbeResult.new(bytes: nil, definitive: range[:received] && head[:received])
      end
      ProbeResult.new(bytes: nil, definitive: false)
    rescue SecurityViolation, URI::InvalidURIError, SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError
      ProbeResult.new(bytes: nil, definitive: false)
    end

    def probe_request(uri, allow_private:, method:, deadline:)
      addresses = Security.network_addresses!(uri.host, purpose: "package source size", allow_private: allow_private)
      last_error = nil

      addresses.each do |address|
        remaining = deadline - Security.monotonic_time
        break if remaining <= 0
        begin
          return probe_address(uri, address, method: method, remaining: remaining)
        rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError => e
          last_error = e
        end
      end
      raise last_error if last_error
      {}
    end

    def probe_address(uri, address, method:, remaining:)
      http = Net::HTTP.new(uri.host, uri.port, nil, nil)
      http.ipaddr = address
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      http.open_timeout = [PROBE_CONNECT_TIMEOUT, remaining].min
      http.read_timeout = [PROBE_READ_TIMEOUT, remaining].min
      http.ssl_timeout = [PROBE_CONNECT_TIMEOUT, remaining].min
      http.max_retries = 0

      request = method == :head ? Net::HTTP::Head.new(uri) : Net::HTTP::Get.new(uri)
      request["User-Agent"] = "Quarks/#{Quarks::VERSION rescue 'dev'}"
      request["Accept-Encoding"] = "identity"
      request["Range"] = "bytes=0-0" if method == :range

      result = { received: false }
      http.start do
        http.request(request) do |response|
          result[:received] = true
          case response
          when Net::HTTPRedirection
            result[:redirect] = response["location"].to_s
          when Net::HTTPPartialContent
            result[:size] = partial_response_size(response)
          when Net::HTTPSuccess
            result[:size] = full_response_size(response)
          else
            result[:size] = unsatisfied_range_size(response) if response.code.to_i == 416
          end
        end
      end
      result
    end

    def partial_response_size(response)
      content_range = response["Content-Range"].to_s
      match = content_range.match(%r{\Abytes\s+\d+-\d+\s*/\s*(\d+)\z}i)
      return unless match
      bytes = Integer(match[1], exception: false)
      bytes if bytes&.positive?
    end

    def unsatisfied_range_size(response)
      content_range = response["Content-Range"].to_s
      match = content_range.match(%r{\Abytes\s+\*/\s*(\d+)\z}i)
      return unless match
      bytes = Integer(match[1], exception: false)
      bytes if bytes&.positive?
    end

    def full_response_size(response)
      bytes = Integer(response["Content-Length"].to_s, exception: false)
      bytes if bytes&.positive?
    end

    def validate_redirect(current_uri, location, allow_http:, allow_private:)
      raise SecurityViolation, "Package source size redirect is missing a location" if location.empty?
      target = URI.join(current_uri.to_s, location)
      if current_uri.scheme == "https" && target.scheme != "https" && !allow_http
        raise SecurityViolation, "Refusing package source size HTTPS downgrade"
      end
      Security.validate_remote_uri!(
        target,
        purpose: "package source size redirect",
        allow_http: allow_http,
        allow_private: allow_private,
        resolve: false
      )
    end

    def load_size_cache
      return {} unless File.exist?(@size_cache_path)
      stat = File.lstat(@size_cache_path)
      return {} unless stat.file? && !stat.symlink? && stat.size <= CACHE_MAX_BYTES
      parsed = JSON.parse(File.binread(@size_cache_path))
      return {} unless parsed.is_a?(Hash)
      entries = parsed["entries"].is_a?(Hash) ? parsed["entries"] : parsed
      entries.each_with_object({}) do |(key, value), out|
        next unless key.to_s.match?(/\A[0-9a-f]{64}\z/)
        if value.is_a?(Hash)
          bytes = Integer(value["bytes"], exception: false)
          unknown_until = Integer(value["unknown_until"], exception: false)
          checked_at = Integer(value["checked_at"], exception: false)
          verified_file = normalize_verified_stamp(value["verified_file"])
          entry = {}
          entry["bytes"] = bytes if bytes&.positive?
          entry["unknown_until"] = unknown_until if unknown_until&.positive?
          entry["checked_at"] = checked_at if checked_at&.positive?
          entry["verified"] = true if value["verified"] == true
          entry["verified_file"] = verified_file if verified_file
          out[key.to_s] = entry unless entry.empty?
        else
          bytes = Integer(value, exception: false)
          out[key.to_s] = { "bytes" => bytes, "checked_at" => 0 } if bytes&.positive?
        end
      end
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def size_cache_dirty?
      @size_cache_mutex.synchronize { !@size_cache_dirty.empty? }
    end

    def persist_size_cache
      directory = File.dirname(@size_cache_path)
      Security.secure_directory(directory)
      lock_path = File.join(directory, "source-sizes.lock")

      @size_cache_mutex.synchronize do
        return true if @size_cache_dirty.empty?
        pending = @size_cache_dirty.dup

        CACHE_WRITE_MUTEX.synchronize do
          flags = File::RDWR | File::CREAT
          flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
          File.open(lock_path, flags, 0o600) do |lock|
            lock.flock(File::LOCK_EX)
            disk = load_size_cache
            merged = merge_size_caches(disk, pending)
            prune_size_cache!(merged)
            Security.atomic_write(@size_cache_path, JSON.generate("version" => 2, "entries" => merged))
            @size_cache = merged
            pending.each_key { |key| @size_cache_dirty.delete(key) }
          ensure
            lock.flock(File::LOCK_UN) rescue nil
          end
        end
      end
      true
    rescue SystemCallError, SecurityViolation
      false
    end

    def merge_size_caches(base, updates)
      merged = base.dup
      updates.each do |key, candidate|
        current = merged[key]
        merged[key] = preferred_cache_entry(current, candidate)
      end
      merged
    end

    def preferred_cache_entry(current, candidate)
      return candidate unless current.is_a?(Hash)
      return current unless candidate.is_a?(Hash)

      current_verified = current["verified"] == true
      candidate_verified = candidate["verified"] == true
      return current if current_verified && !candidate_verified
      return candidate if candidate_verified && !current_verified

      current_checked = Integer(current["checked_at"], exception: false).to_i
      candidate_checked = Integer(candidate["checked_at"], exception: false).to_i
      return candidate if candidate_checked > current_checked
      return current if current_checked > candidate_checked

      current_bytes = Integer(current["bytes"], exception: false)
      candidate_bytes = Integer(candidate["bytes"], exception: false)
      return candidate if candidate_bytes&.positive? && !current_bytes&.positive?
      return current if current_bytes&.positive? && !candidate_bytes&.positive?
      candidate
    end

    def prune_size_cache!(cache)
      now = Time.now.to_i
      cache.delete_if do |_key, entry|
        next true unless entry.is_a?(Hash)
        bytes = Integer(entry["bytes"], exception: false)
        unknown_until = Integer(entry["unknown_until"], exception: false)
        checked_at = Integer(entry["checked_at"], exception: false).to_i
        verified = entry["verified"] == true
        stale_advisory = bytes&.positive? && !verified && checked_at < now - ADVISORY_CACHE_TTL
        missing_size = !bytes&.positive? && (!unknown_until || unknown_until <= now)
        stale_advisory || missing_size
      end
      return if cache.length <= 4096

      ordered = cache.sort_by do |_key, entry|
        entry.is_a?(Hash) ? Integer(entry["checked_at"], exception: false).to_i : 0
      end
      ordered.first(cache.length - 4096).each { |key, _entry| cache.delete(key) }
    end

    def local_source_path(source)
      return unless source.start_with?("file://")

      path = File.expand_path(URI.parse(source).path)
      path if File.file?(path) && !File.symlink?(path)
    rescue URI::InvalidURIError
      nil
    end

    def declared_size(package, source)
      raw = package.source_sizes[source] || package.source_sizes[source.to_s]
      size = Integer(raw, exception: false)
      size if size&.positive?
    end

    def cached_source_bytes(path, package, source)
      return unless path
      stat = File.lstat(path)
      return unless stat.file? && !stat.symlink?

      declared = declared_size(package, source)
      return if declared && stat.size != declared

      key = size_cache_key(package, source)
      cache_entry = @size_cache_mutex.synchronize { @size_cache[key] }
      if cache_entry.is_a?(Hash)
        cached_bytes = Integer(cache_entry["bytes"], exception: false)
        stamp = normalize_verified_stamp(cache_entry["verified_file"])
        return stat.size if cached_bytes == stat.size && stamp && stamp == file_stamp_from_stat(stat)
      end

      return unless valid_source_file?(path, package, source, stat: stat)
      store_cache_entry(key, bytes: stat.size, checked_at: Time.now.to_i, verified: true, verified_file: file_stamp_from_stat(stat))
      stat.size
    rescue SystemCallError
      nil
    end

    def file_stamp(path)
      stat = File.lstat(path)
      return unless stat.file? && !stat.symlink?
      file_stamp_from_stat(stat)
    rescue SystemCallError
      nil
    end

    def file_stamp_from_stat(stat)
      {
        "dev" => stat.dev,
        "ino" => stat.ino,
        "size" => stat.size,
        "mtime_ns" => stat.mtime.to_i * 1_000_000_000 + stat.mtime.nsec
      }
    end

    def normalize_verified_stamp(value)
      return unless value.is_a?(Hash)
      stamp = {}
      %w[dev ino size mtime_ns].each do |key|
        parsed = Integer(value[key], exception: false)
        return unless parsed
        stamp[key] = parsed
      end
      stamp
    end

    def valid_source_file?(path, package, source, stat: nil)
      return false unless path
      stat ||= File.lstat(path)
      return false unless stat.file? && !stat.symlink?

      declared = declared_size(package, source)
      return false if declared && stat.size != declared

      checksum = package.checksums[source] || package.checksums[source.to_s]
      return false unless checksum.is_a?(Hash)

      algorithm = checksum[:algorithm] || checksum["algorithm"] || "sha256"
      expected = checksum[:hash] || checksum["hash"]
      cache_key = [path, stat.dev, stat.ino, stat.size, stat.mtime.to_i, stat.mtime.nsec, algorithm.to_s, expected.to_s]
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
