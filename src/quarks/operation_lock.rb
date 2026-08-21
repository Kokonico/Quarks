# frozen_string_literal: true

require "digest"
require "fileutils"
require "quarks/env"
require "quarks/security"

module Quarks
  class OperationLock
    class BusyError < StandardError; end

    def self.synchronize(name, &block)
      new(name).synchronize(&block)
    end

    def initialize(name)
      digest = Digest::SHA256.hexdigest(name.to_s)[0, 24]
      @directory = File.join(Quarks::Env.state_root, "var", "lock", "quarks")
      @path = File.join(@directory, "#{digest}.lock")
    end

    def synchronize
      Security.secure_directory(@directory)
      flags = File::RDWR | File::CREAT
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(@path, flags, 0o600) do |file|
        File.chmod(0o600, @path)
        unless file.flock(File::LOCK_EX | File::LOCK_NB)
          holder = file.read.to_s.strip
          detail = holder.empty? ? "another Quarks process" : "process #{holder}"
          raise BusyError, "Operation is already locked by #{detail}"
        end

        file.rewind
        file.truncate(0)
        file.write(Process.pid.to_s)
        file.flush
        file.fsync
        yield
      ensure
        file.flock(File::LOCK_UN) rescue nil
      end
    rescue Errno::ELOOP
      raise SecurityViolation, "Operation lock must not be a symlink: #{@path}"
    end
  end
end
