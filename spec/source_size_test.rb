require "minitest/autorun"
require "digest"
require "fileutils"
require "socket"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../src", __dir__))
require "quarks/package"
require "quarks/source_size"

class SourceSizeNetworkTest < Minitest::Test
  def setup
    @old_http = ENV["QUARKS_ALLOW_INSECURE_SOURCES"]
    @old_private = ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"]
    @old_probe = ENV["QUARKS_SIZE_PROBE_MS"]
    @old_jobs = ENV["QUARKS_JOBS"]
    ENV["QUARKS_ALLOW_INSECURE_SOURCES"] = "1"
    ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] = "1"
    Quarks::Security.clear_dns_cache!
  end

  def teardown
    ENV["QUARKS_ALLOW_INSECURE_SOURCES"] = @old_http
    ENV["QUARKS_ALLOW_PRIVATE_NETWORKS"] = @old_private
    ENV["QUARKS_SIZE_PROBE_MS"] = @old_probe
    ENV["QUARKS_JOBS"] = @old_jobs
    @server&.close rescue nil
    @server_thread&.kill
    @server_thread&.join(0.1)
  end

  def test_range_total_survives_redirect_and_is_cached
    requests = 0
    start_server do |request, socket|
      requests += 1
      path = request.lines.first.to_s.split[1]
      if path == "/redirect"
        socket.write("HTTP/1.1 302 Found\r\nLocation: /source\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      else
        socket.write("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/12345\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
      end
    end

    Dir.mktmpdir do |state|
      package, = package_for("/redirect")
      result = Quarks::SourceSize.new(state_root: state).measure_many([package], probe_remote: true).fetch(package.atom)
      assert_equal 12_345, result.download_bytes
      assert_equal 0, result.unknown_sources
      assert_empty package.source_sizes

      first_requests = requests
      cached = Quarks::SourceSize.new(state_root: state).measure_many([package], probe_remote: true).fetch(package.atom)
      assert_equal 12_345, cached.download_bytes
      assert_equal first_requests, requests
    end
  end

  def test_partial_content_length_is_not_mistaken_for_total_size
    start_server do |request, socket|
      if request.start_with?("HEAD ")
        socket.write("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n")
      else
        socket.write("HTTP/1.1 206 Partial Content\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
      end
    end

    Dir.mktmpdir do |state|
      package, = package_for("/source")
      result = Quarks::SourceSize.new(state_root: state).measure_many([package], probe_remote: true).fetch(package.atom)
      assert_equal 0, result.download_bytes
      assert_equal 1, result.unknown_sources
    end
  end

  def test_probe_budget_bounds_slow_metadata_servers
    ENV["QUARKS_SIZE_PROBE_MS"] = "150"
    start_server do |_request, socket|
      sleep 1
      socket.write("HTTP/1.1 200 OK\r\nContent-Length: 999\r\nConnection: close\r\n\r\n") rescue nil
    end

    Dir.mktmpdir do |state|
      package, = package_for("/slow")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = Quarks::SourceSize.new(state_root: state).measure_many([package], probe_remote: true).fetch(package.atom)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 0.5
      assert_equal 1, result.unknown_sources
    end
  end

  def test_range_not_satisfiable_can_report_resource_size
    start_server do |_request, socket|
      socket.write("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */54321\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    end

    Dir.mktmpdir do |state|
      package, = package_for("/range")
      result = Quarks::SourceSize.new(state_root: state).measure_many([package], probe_remote: true).fetch(package.atom)
      assert_equal 54_321, result.download_bytes
      assert_equal 0, result.unknown_sources
    end
  end

  def test_size_probes_are_not_serialized_by_build_jobs
    ENV["QUARKS_JOBS"] = "1"
    ENV["QUARKS_SIZE_PROBE_MS"] = "500"
    start_server do |_request, socket|
      sleep 0.08
      socket.write("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-0/1000\r\nContent-Length: 1\r\nConnection: close\r\n\r\nx")
    end

    Dir.mktmpdir do |state|
      packages = 6.times.map { |index| package_for("/source-#{index}", name: "demo#{index}").first }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      results = Quarks::SourceSize.new(state_root: state).measure_many(packages, probe_remote: true)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      assert_operator elapsed, :<, 0.4
      assert_equal [0], results.values.map(&:unknown_sources).uniq
      assert_equal [1000], results.values.map(&:download_bytes).uniq
    end
  end

  def test_independent_cache_writers_merge_verified_sizes
    Dir.mktmpdir do |state|
      first = standalone_package("first", "https://example.invalid/first.tar.xz")
      second = standalone_package("second", "https://example.invalid/second.tar.xz")
      first_cache = Quarks::SourceSize.new(state_root: state)
      second_cache = Quarks::SourceSize.new(state_root: state)

      assert first_cache.record_verified(first, first.sources.first, 111)
      assert second_cache.record_verified(second, second.sources.first, 222)

      measured = Quarks::SourceSize.new(state_root: state).measure_many([first, second], probe_remote: true)
      assert_equal 111, measured.fetch(first.atom).download_bytes
      assert_equal 222, measured.fetch(second.atom).download_bytes
    end
  end

  private

  def start_server(&handler)
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @server_thread = Thread.new do
      loop do
        socket = @server.accept
        Thread.new(socket) do |client|
          request = +""
          while (line = client.gets)
            request << line
            break if line == "\r\n"
          end
          handler.call(request, client)
        ensure
          client.close rescue nil
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def package_for(path, name: "demo")
    package = Quarks::Package.new(name)
    package.category = "app"
    package.version = "1"
    source = "http://127.0.0.1:#{@port}#{path}"
    package.sources = [source]
    package.checksums[source] = { algorithm: "sha256", hash: Digest::SHA256.hexdigest("unused") }
    [package, source]
  end

  def standalone_package(name, source)
    package = Quarks::Package.new(name)
    package.category = "app"
    package.version = "1"
    package.sources = [source]
    package.checksums[source] = { algorithm: "sha256", hash: Digest::SHA256.hexdigest(name) }
    package
  end
end
