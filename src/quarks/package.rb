# frozen_string_literal: true

require "json"

module Quarks
  class NucleiError < StandardError; end

  class NucleiParseError < NucleiError
    attr_reader :path, :original

    def initialize(path, msg, original: nil)
      @path = path.to_s
      @original = original
      super(msg)
    end
  end

  class NucleiSchemaError < NucleiError
    attr_reader :path

    def initialize(path, msg)
      @path = path.to_s
      super(msg)
    end
  end

  class Package
    attr_accessor :name, :version, :description, :homepage, :license, :category
    attr_accessor :dependencies, :build_dependencies, :host_tools
    attr_accessor :sources, :checksums
    attr_accessor :configure_flags, :build_commands, :install_commands
    attr_accessor :patches, :environment
    attr_accessor :build_system, :build_dir, :install_prefix
    attr_accessor :make_args, :cmake_args, :meson_args
    attr_accessor :slot, :subslot
    attr_accessor :blocks, :blocked_by
    attr_accessor :use_dependencies, :provided_use
    attr_accessor :required_use, :iuse
    attr_accessor :provided_by
    attr_accessor :src_uri, :homepage
    attr_accessor :restrict

    def initialize(name)
      @name = name.to_s
      @version = "0.0.0"

      @description = ""
      @homepage = ""
      @license = "Unknown"
      @category = "app"

      @dependencies = []
      @build_dependencies = []
      @host_tools = []

      @sources = []
      @checksums = {}

      @configure_flags = []
      @build_commands = []
      @install_commands = []

      @patches = []
      @environment = {}

      @build_system = :auto
      @build_dir = "build"
      @install_prefix = "/usr"

      @make_args = []
      @cmake_args = []
      @meson_args = []

      @slot = nil
      @subslot = nil
      @blocks = []
      @blocked_by = []
      @use_dependencies = []
      @provided_use = []
      @required_use = []
      @iuse = []
      @provided_by = nil
      @src_uri = nil
      @restrict = []
    end

    def atom
      "#{@category}/#{@name}"
    end

    def full_name
      "#{@name}-#{@version}"
    end

    def to_metadata
      {
        name: @name,
        version: @version,
        description: @description,
        homepage: @homepage,
        license: @license,
        category: @category,
        dependencies: @dependencies,
        build_dependencies: @build_dependencies,
        host_tools: @host_tools,
        sources: @sources,
        checksums: @checksums,
        configure_flags: @configure_flags,
        build_commands: @build_commands,
        install_commands: @install_commands,
        patches: @patches,
        environment: @environment,
        build_system: @build_system,
        build_dir: @build_dir,
        install_prefix: @install_prefix,
        make_args: @make_args,
        cmake_args: @cmake_args,
        meson_args: @meson_args,
        slot: @slot,
        subslot: @subslot,
        blocks: @blocks,
        blocked_by: @blocked_by,
        use_dependencies: @use_dependencies,
        provided_use: @provided_use,
        required_use: @required_use,
        iuse: @iuse
      }
    end

    def to_h
      {
        name: @name,
        atom: atom,
        version: @version,
        full_name: full_name,
        description: @description,
        homepage: @homepage,
        license: @license,
        category: @category,
        dependencies: @dependencies,
        build_dependencies: @build_dependencies,
        slot: @slot || "0",
        subslot: @subslot,
        blocks: @blocks,
        use_dependencies: @use_dependencies,
        iuse: @iuse,
        sources: @sources,
        build_system: @build_system.to_s
      }
    end

    def save_metadata(path)
      ::File.write(path, ::JSON.pretty_generate(to_metadata))
    end

    def validate!(path: "(unknown)")
      raise NucleiSchemaError.new(path, "Package name is missing") if @name.to_s.strip.empty?
      raise NucleiSchemaError.new(path, "Package version is missing") if @version.to_s.strip.empty?
      raise NucleiSchemaError.new(path, "Package category is missing") if @category.to_s.strip.empty?

      dup_sources = @sources.group_by(&:itself).select { |_, v| v.length > 1 }.keys
      raise NucleiSchemaError.new(path, "Duplicate source entries: #{dup_sources.join(', ')}") if dup_sources.any?

      unknown_patches = @patches.reject { |p| p.is_a?(Hash) && p[:file].to_s.strip != "" }
      raise NucleiSchemaError.new(path, "Malformed patch declarations: #{unknown_patches.inspect}") if unknown_patches.any?

      true
    end

    def self.load_from_nuclei(path, strict: true)
      path = path.to_s
      raise NucleiParseError.new(path, "Nuclei file not found: #{path}") unless ::File.exist?(path)

      content = ::File.read(path)
      dsl = NucleiDSL.new(path: path, strict: strict)

      begin
        dsl.instance_eval(content, path, 1)
      rescue ::Exception => e
        bt = e.backtrace&.find { |x| x.include?(path) }.to_s rescue ""
        loc = bt.empty? ? "" : " at: #{bt}"
        raise NucleiParseError.new(path, "Failed to parse #{path}: #{e.class}: #{e.message}#{loc}", original: e)
      end

      pkg = dsl.package
      if pkg.nil?
        inferred = ::File.basename(path, ".nuclei")
        pkg = Package.new(inferred)
        dsl.__attach_package__(pkg)

        begin
          dsl.instance_eval(content, path, 1)
        rescue ::Exception => e
          bt = e.backtrace&.find { |x| x.include?(path) }.to_s rescue ""
          loc = bt.empty? ? "" : " at: #{bt}"
          raise NucleiParseError.new(path, "Failed to parse #{path} (implicit nuclei): #{e.class}: #{e.message}#{loc}", original: e)
        end
      end

      pkg.validate!(path: path) if strict
      pkg
    end
  end

  class NucleiDSL < BasicObject
    attr_reader :package

    def initialize(path:, strict: false)
      @path = path.to_s
      @strict = !!strict
      @package = nil
    end

    def __attach_package__(pkg)
      @package = pkg
    end

    def nuclei(name = nil, version = nil, &block)
      if name.nil? && version.nil?
        ensure_pkg!
        instance_eval(&block) if block
        return @package
      end

      if !name.nil? && version.nil?
        @package = ::Quarks::Package.new(name.to_s)
        instance_eval(&block) if block
        return @package
      end

      @package = ::Quarks::Package.new(name.to_s)
      @package.version = version.to_s
      instance_eval(&block) if block
      @package
    end

    def name(v) ensure_pkg!; @package.name = v.to_s end
    def version(v) ensure_pkg!; @package.version = v.to_s end
    def desc(v = nil) ensure_pkg!; @package.description = v.to_s end
    def description(v = nil) ensure_pkg!; @package.description = v.to_s end
    def homepage(v) ensure_pkg!; @package.homepage = v.to_s end
    def license(v) ensure_pkg!; @package.license = v.to_s end
    def category(v) ensure_pkg!; @package.category = v.to_s end

    def depends(*deps)
      ensure_pkg!
      @package.dependencies.concat(norm_list(deps))
      @package.dependencies.uniq!
      true
    end

    def build_depends(*deps)
      ensure_pkg!
      @package.build_dependencies.concat(norm_list(deps))
      @package.build_dependencies.uniq!
      true
    end

    def host_tools(*tools)
      ensure_pkg!
      @package.host_tools.concat(norm_list(tools))
      @package.host_tools.uniq!
      true
    end

    def dep(*deps) depends(*deps) end
    def bdep(*deps) build_depends(*deps) end
    def build_dependencies(*deps) build_depends(*deps) end

    def source(url, checksum: nil, algorithm: "sha256", sha256: nil, sha512: nil, md5: nil, **kw)
      ensure_pkg!
      u = url.to_s
      @package.sources << u unless @package.sources.include?(u)

      if sha256
        checksum = sha256
        algorithm = "sha256"
      elsif sha512
        checksum = sha512
        algorithm = "sha512"
      elsif md5
        checksum = md5
        algorithm = "md5"
      end

      checksum ||= kw[:hash] if kw.key?(:hash)
      algorithm = kw[:algo].to_s if kw.key?(:algo)

      if checksum
        @package.checksums[u] = { hash: checksum.to_s, algorithm: algorithm.to_s }
      end

      true
    end

    def configure(*flags)
      ensure_pkg!
      @package.configure_flags.concat(norm_list(flags))
      true
    end

    def meson_args(*args)
      ensure_pkg!
      return @package.meson_args if args.empty?
      @package.meson_args.concat(norm_list(args))
      true
    end

    def cmake_args(*args)
      ensure_pkg!
      return @package.cmake_args if args.empty?
      @package.cmake_args.concat(norm_list(args))
      true
    end

    def make_args(*args)
      ensure_pkg!
      return @package.make_args if args.empty?
      @package.make_args.concat(norm_list(args))
      true
    end

    def env(key = nil, value = nil, **kv)
      ensure_pkg!
      unless kv.empty?
        kv.each { |k, v| @package.environment[k.to_s] = v.to_s }
        return true
      end
      @package.environment[key.to_s] = value.to_s
      true
    end

    def patch(file, strip: 1)
      ensure_pkg!
      @package.patches << { file: file.to_s, strip: strip.to_i }
      true
    end

    def build_system(v)
      ensure_pkg!
      @package.build_system = v.to_sym
      true
    end

    def build_dir(v)
      ensure_pkg!
      @package.build_dir = v.to_s
      true
    end

    def install_prefix(v)
      ensure_pkg!
      @package.install_prefix = v.to_s
      true
    end

    def slot(v, subslot = nil)
      ensure_pkg!
      @package.slot = v.to_s
      @package.subslot = subslot.to_s if subslot
      true
    end

    def subslot(v)
      ensure_pkg!
      @package.subslot = v.to_s
      true
    end

    def blocks(*packages)
      ensure_pkg!
      @package.blocks.concat(norm_list(packages))
      true
    end

    def blocked_by(*packages)
      ensure_pkg!
      @package.blocked_by.concat(norm_list(packages))
      true
    end

    def use_dep(flag, *deps, condition: :enabled)
      ensure_pkg!
      @package.use_dependencies << {
        flag: flag.to_s,
        dependencies: norm_list(deps),
        condition: condition
      }
      true
    end

    def iuse(*flags)
      ensure_pkg!
      @package.iuse.concat(norm_list(flags))
      true
    end

    def required_use(*flags)
      ensure_pkg!
      @package.required_use.concat(norm_list(flags))
      true
    end

    def provided_use(*flags)
      ensure_pkg!
      @package.provided_use.concat(norm_list(flags))
      true
    end

    def provided_by(pkg)
      ensure_pkg!
      @package.provided_by = pkg.to_s
      true
    end

    def restrict(*restrictions)
      ensure_pkg!
      @package.restrict.concat(norm_list(restrictions))
      true
    end

    def build(&block)
      ensure_pkg!
      ::Kernel.raise ::Quarks::NucleiParseError.new(@path, "build do ... end requires a block") unless block

      ctx = ::Quarks::BuildContext.new(@package, path: @path)
      ctx.instance_eval(&block)
      true
    end

    def run(*)
      ::Kernel.raise ::Quarks::NucleiParseError.new(@path, "Use `run` only inside build do ... end")
    end

    def install(*)
      ::Kernel.raise ::Quarks::NucleiParseError.new(@path, "Use `install` only inside build do ... end")
    end

    def system(*args)
      ::Kernel.raise ::Quarks::NucleiParseError.new(@path,
        "nuclei cannot execute commands at load-time: system(#{args.inspect}). Put it inside build do ... end")
    end

    def `(cmd)
      ::Kernel.raise ::Quarks::NucleiParseError.new(@path,
        "nuclei cannot execute commands at load-time: `#{cmd}`. Put it inside build do ... end")
    end

    def exec(*args)
      ::Kernel.raise ::Quarks::NucleiParseError.new(@path,
        "nuclei cannot exec at load-time: exec(#{args.inspect}). Put it inside build do ... end")
    end

    def method_missing(meth, *args, &block)
      return true if block && args.empty?
      ::Kernel.raise ::Quarks::NucleiParseError.new(@path, "Unknown nuclei directive '#{meth}'. args=#{args.inspect}")
    end

    def respond_to_missing?(*)
      false
    end

    private

    def ensure_pkg!
      return if @package
      inferred = ::File.basename(@path, ".nuclei")
      @package = ::Quarks::Package.new(inferred)
    end

    def norm_list(args)
      args.flatten.compact.map(&:to_s)
    end
  end

  class BuildContext < BasicObject
    def initialize(pkg, path:)
      @pkg = pkg
      @path = path.to_s
    end

    def run(*commands)
      @pkg.build_commands.concat(norm_list(commands))
      true
    end

    def install(*commands)
      @pkg.install_commands.concat(norm_list(commands))
      true
    end

    def configure(*flags)
      if flags.flatten.compact.empty?
        extras = @pkg.configure_flags.join(" ").strip
        @pkg.build_commands << "./configure #{extras}".strip
      else
        @pkg.build_commands << "./configure #{norm_list(flags).join(' ')}".strip
      end
      true
    end

    def cmake(*args)
      @pkg.build_commands << "cmake #{norm_list(args).join(' ')}".strip
      true
    end

    def meson(*args)
      @pkg.build_commands << "meson #{norm_list(args).join(' ')}".strip
      true
    end

    def ninja(*args)
      @pkg.build_commands << "ninja #{norm_list(args).join(' ')}".strip
      true
    end

    def make(*targets)
      ts = norm_list(targets)
      if ts.empty?
        @pkg.build_commands << "make"
      else
        ts.each { |t| @pkg.build_commands << "make #{t}" }
      end
      true
    end

    def system(*args)
      @pkg.build_commands << norm_list(args).join(" ")
      true
    end

    def exec(*args)
      @pkg.build_commands << norm_list(args).join(" ")
      true
    end

    def `(cmd)
      @pkg.build_commands << cmd.to_s
      ""
    end

    def meson_args
      @pkg.meson_args
    end

    def cmake_args
      @pkg.cmake_args
    end

    def make_args
      @pkg.make_args
    end

    def method_missing(meth, *args, &block)
      return true if block && args.empty?
      ::Kernel.raise ::Quarks::NucleiParseError.new(@path, "Unknown build directive '#{meth}'. args=#{args.inspect}")
    end

    def respond_to_missing?(*)
      false
    end

    private

    def norm_list(args)
      args.flatten.compact.map(&:to_s)
    end
  end
end
