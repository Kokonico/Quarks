# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require "resolv"
require "securerandom"
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

    def validate_remote_uri!(value, purpose:, allow_http: false, allow_private: false)
      uri = value.is_a?(URI) ? value : URI.parse(value.to_s)
      schemes = allow_http ? %w[http https] : %w[https]
      raise SecurityViolation, "#{purpose} must use #{schemes.join(' or ')}" unless schemes.include?(uri.scheme)
      raise SecurityViolation, "#{purpose} URL must include a host" if uri.host.to_s.empty?
      raise SecurityViolation, "#{purpose} URL must not contain credentials" if uri.userinfo

      resolve_public_addresses!(uri.host, purpose: purpose) unless allow_private
      uri
    rescue URI::InvalidURIError => e
      raise SecurityViolation, "Invalid #{purpose} URL: #{e.message}"
    end

    def validate_public_host!(host, purpose:)
      resolve_public_addresses!(host, purpose: purpose)
      true
    end

    def resolve_public_addresses!(host, purpose:)
      addresses = Resolv.getaddresses(host.to_s)
      raise SecurityViolation, "#{purpose} host did not resolve: #{host}" if addresses.empty?

      addresses.each do |address|
        ip = IPAddr.new(address)
        ip = ip.native if ip.ipv4_mapped?
        if PRIVATE_NETWORKS.any? { |network| network.include?(ip) }
          raise SecurityViolation, "#{purpose} resolves to a non-public address: #{address}"
        end
      end
      addresses
    rescue Resolv::ResolvError, IPAddr::InvalidAddressError => e
      raise SecurityViolation, "Could not validate #{purpose} host #{host}: #{e.message}"
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
  end
end
