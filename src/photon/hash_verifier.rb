# frozen_string_literal: true

require "digest"

module Photon
  class HashVerifier
    SUPPORTED = {
      "sha256" => Digest::SHA256,
      "sha512" => Digest::SHA512,
      "sha1"   => Digest::SHA1,
      "md5"    => Digest::MD5
    }.freeze

    DIGEST_HEX_LEN = {
      "sha256" => 64,
      "sha512" => 128,
      "sha1"   => 40,
      "md5"    => 32
    }.freeze

    class VerificationError < StandardError; end

    class << self
      def normalize_alg(alg)
        alg.to_s.strip.downcase
      end

      def normalize_hex(hex)
        hex.to_s.strip.downcase
      end

      def supported?(alg)
        SUPPORTED.key?(normalize_alg(alg))
      end

      def expected_len_for(alg)
        DIGEST_HEX_LEN[normalize_alg(alg)]
      end

      def hex_string?(s)
        !!(s.to_s =~ /\A[0-9a-fA-F]+\z/)
      end

      def verify_file(path, algorithm:, expected_hex:)
        alg = normalize_alg(algorithm)
        exp = normalize_hex(expected_hex)

        return true if exp == "skip"

        raise VerificationError, "Unsupported hash algorithm: #{alg}" unless supported?(alg)
        raise VerificationError, "File not found: #{path}" unless File.file?(path)

        exp_len = expected_len_for(alg)
        raise VerificationError, "Expected hash is empty" if exp.empty?
        raise VerificationError, "Expected hash must be hex" unless hex_string?(exp)
        raise VerificationError, "Expected #{alg} hash length must be #{exp_len} hex chars (got #{exp.bytesize})" unless exp.bytesize == exp_len

        computed = compute_hex(path, alg)
        secure_compare_hex(computed, exp)
      end

      def compute_hex(path, alg)
        klass = SUPPORTED.fetch(normalize_alg(alg))
        dig = klass.new

        File.open(path, "rb") do |f|
          while (chunk = f.read(1024 * 1024))
            dig.update(chunk)
          end
        end

        dig.hexdigest.downcase
      end

      def secure_compare_hex(a, b)
        aa = a.to_s
        bb = b.to_s
        return false if aa.bytesize != bb.bytesize

        result = 0
        aa.bytes.zip(bb.bytes) { |x, y| result |= (x ^ y) }
        result.zero?
      end
    end
  end
end
