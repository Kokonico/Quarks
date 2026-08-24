# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require "securerandom"
require "socket"
require "thread"
require "uri"

module Quarks
  class SecurityViolation < StandardError; end

  module Security
    module_function

    PRIVATE_NETWORKS = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8
      169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
      192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
      224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
      ::/96 64:ff9b::/96 64:ff9b:1::/48 100::/64 100:0:0:1::/64
      2001::/23 2001:db8::/32 2002::/16 3fff::/20 5f00::/16
      fec0::/10
    ].map { |cidr| IPAddr.new(cidr) }.freeze
    DNS_CACHE_TTL = 30.0
    DNS_CACHE_MAX = 256

    @dns_cache = {}
    @dns_cache_mutex = Mutex.new
    @dns_locks = Array.new(32) { Mutex.new }.freeze

    def validate_remote_uri!(value, purpose:, allow_http: false, allow_private: false, resolve: true)
      uri = value.is_a?(URI) ? value : URI.parse(value.to_s)
      schemes = allow_http ? %w[http https] : %w[https]
      raise SecurityViolation, "#{purpose} must use #{schemes.join(' or ')}" unless schemes.include?(uri.scheme)
      raise SecurityViolation, "#{purpose} URL must include a host" if uri.host.to_s.empty?
      raise SecurityViolation, "#{purpose} URL must not contain credentials" if uri.userinfo

      network_addresses!(uri.host, purpose: purpose, allow_private: allow_private) if resolve
      uri
    rescue URI::InvalidURIError => e
      raise SecurityViolation, "Invalid #{purpose} URL: #{e.message}"
    end

    def validate_public_host!(host, purpose:)
      resolve_public_addresses!(host, purpose: purpose)
      true
    end

    def network_addresses!(host, purpose:, allow_private: false)
      addresses = resolve_addresses!(host, purpose: purpose)
      return addresses if allow_private

      addresses.each do |address|
        ip = IPAddr.new(address)
        ip = ip.native if ip.ipv4_mapped?
        if PRIVATE_NETWORKS.any? { |network| network.include?(ip) }
          raise SecurityViolation, "#{purpose} resolves to a non-public address: #{address}"
        end
      end
      addresses
    rescue IPAddr::InvalidAddressError => e
      raise SecurityViolation, "Could not validate #{purpose} host #{host}: #{e.message}"
    end

    def resolve_public_addresses!(host, purpose:)
      network_addresses!(host, purpose: purpose, allow_private: false)
    end

    def resolve_addresses!(host, purpose:)
      value = host.to_s.strip
      raise SecurityViolation, "#{purpose} host is empty" if value.empty?

      literal = IPAddr.new(value) rescue nil
      return [literal.to_s] if literal

      now = monotonic_time
      cached = cached_addresses(value, now)
      return cached if cached

      @dns_locks[value.hash % @dns_locks.length].synchronize do
        now = monotonic_time
        cached = cached_addresses(value, now)
        return cached if cached

        addresses = Addrinfo.getaddrinfo(value, nil, nil, :STREAM).filter_map do |address|
          address.ip_address if address.ip?
        end.uniq
        raise SecurityViolation, "#{purpose} host did not resolve: #{value}" if addresses.empty?

        addresses.sort_by! do |address|
          ip = IPAddr.new(address)
          ip.ipv4? ? 0 : 1
        rescue IPAddr::InvalidAddressError
          2
        end

        @dns_cache_mutex.synchronize do
          @dns_cache.delete_if { |_key, entry| entry[:expires_at] <= now }
          @dns_cache.shift while @dns_cache.length >= DNS_CACHE_MAX
          @dns_cache[value] = { addresses: addresses.freeze, expires_at: now + DNS_CACHE_TTL }
        end
        addresses.dup
      end
    rescue SocketError => e
      raise SecurityViolation, "Could not resolve #{purpose} host #{value}: #{e.message}"
    end

    def cached_addresses(host, now)
      @dns_cache_mutex.synchronize do
        entry = @dns_cache[host]
        entry && entry[:expires_at] > now ? entry[:addresses].dup : nil
      end
    end

    def clear_dns_cache!
      @dns_cache_mutex.synchronize { @dns_cache.clear }
      true
    end

    def path_within?(path, root, allow_root: true)
      candidate = File.expand_path(path.to_s)
      boundary = File.expand_path(root.to_s)
      return allow_root if candidate == boundary

      prefix = boundary == File::SEPARATOR ? File::SEPARATOR : "#{boundary}#{File::SEPARATOR}"
      candidate.start_with?(prefix)
    rescue ArgumentError
      false
    end

    def atomic_write(path, content, mode: 0o600)
      destination = File.expand_path(path)
      directory = File.dirname(destination)
      FileUtils.mkdir_p(directory, mode: 0o700)
      temporary = File.join(directory, ".#{File.basename(path)}.tmp-#{Process.pid}-#{SecureRandom.hex(6)}")

      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        File.chmod(mode, temporary)
        file.write(content)
        file.flush
        file.fsync
      end
      File.rename(temporary, destination)
      File.open(directory, File::RDONLY) { |dir| dir.fsync }
      true
    ensure
      FileUtils.rm_f(temporary) if defined?(temporary) && temporary && File.exist?(temporary)
    end

    def secure_directory(path, mode: 0o700)
      destination = File.expand_path(path.to_s)
      if File.symlink?(destination)
        raise SecurityViolation, "Secure directory must not be a symlink: #{destination}"
      end
      if File.exist?(destination) && !File.directory?(destination)
        raise SecurityViolation, "Secure directory path is not a directory: #{destination}"
      end

      FileUtils.mkdir_p(destination, mode: mode)
      stat = File.lstat(destination)
      raise SecurityViolation, "Secure directory became a symlink: #{destination}" if stat.symlink?
      File.chmod(mode, destination)
      destination
    end

    def monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
