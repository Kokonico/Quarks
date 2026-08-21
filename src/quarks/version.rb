# frozen_string_literal: true

require "rubygems/version"

module Quarks
  VERSION = "2.0.0" unless const_defined?(:VERSION, false)

  module Versioning
    module_function

    def compare(left, right)
      left_epoch, left_body, left_revision = split(left)
      right_epoch, right_body, right_revision = split(right)

      epoch_cmp = left_epoch <=> right_epoch
      return epoch_cmp unless epoch_cmp.zero?

      body_cmp = gem_version(left_body) <=> gem_version(right_body)
      return body_cmp unless body_cmp.zero?

      left_revision <=> right_revision
    rescue ArgumentError
      fallback_tokens(left) <=> fallback_tokens(right)
    end

    def newer?(candidate, installed)
      compare(candidate, installed).positive?
    end

    def split(value)
      raw = value.to_s.strip
      epoch = 0
      if (match = raw.match(/\A(\d+):(.*)\z/))
        epoch = match[1].to_i
        raw = match[2]
      end

      revision = 0
      if (match = raw.match(/\A(.*)-r(\d+)\z/i))
        raw = match[1]
        revision = match[2].to_i
      end
      [epoch, raw, revision]
    end

    def gem_version(value)
      normalized = value.to_s.downcase
                        .gsub(/[_+-]+/, ".")
                        .gsub(/(?<=\d)(?=[a-z])|(?<=[a-z])(?=\d)/, ".")
                        .gsub(/\.{2,}/, ".")
                        .sub(/\A\./, "")
                        .sub(/\.\z/, "")
      Gem::Version.new(normalized.empty? ? "0" : normalized)
    end

    def fallback_tokens(value)
      value.to_s.downcase.scan(/\d+|[a-z]+/).map do |token|
        token.match?(/\A\d+\z/) ? [1, token.to_i] : [0, token]
      end
    end
  end
end
