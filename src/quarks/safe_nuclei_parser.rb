# frozen_string_literal: true

require "ripper"

module Quarks
  class SafeNucleiParser
    PACKAGE_DIRECTIVES = %w[
      name version desc description homepage license category
      depends build_depends build_dependencies host_tools source configure
      meson_args cmake_args make_args env patch build_system build_dir
      install_prefix slot subslot blocks blocked_by use_dep iuse required_use
      provided_use provided_by restrict
    ].freeze

    BUILD_DIRECTIVES = %w[
      run install configure cmake meson ninja make system exec
    ].freeze

    class ParseError < StandardError; end

    def initialize(path:, strict: true)
      @path = path.to_s
      @strict = strict
    end

    def parse(content)
      tree = Ripper.sexp(content)
      raise_error("invalid Ruby syntax") unless tree

      statements = program_statements(tree)
      raise_error("recipe must contain exactly one nuclei block") unless statements.length == 1

      outer = statements.first
      raise_error("recipe must be a nuclei ... do block") unless node_type(outer) == :method_add_block

      name, args, kwargs = parse_call(outer[1])
      raise_error("recipe must start with nuclei") unless name == "nuclei"
      raise_error("nuclei does not accept keyword arguments") unless kwargs.empty?
      raise_error("nuclei requires a package name and version") unless args.length == 2

      package = Package.new(args[0].to_s)
      package.version = args[1].to_s
      parse_package_body(package, block_statements(outer[2]))
      package.validate!(path: @path) if @strict
      package
    rescue ParseError => e
      raise NucleiParseError.new(@path, e.message, original: e)
    end

    private

    def parse_package_body(package, statements)
      statements.each do |statement|
        if node_type(statement) == :method_add_block
          directive, args, kwargs = parse_call(statement[1])
          raise_error("only build do ... end blocks are allowed") unless directive == "build"
          raise_error("build does not accept arguments") unless args.empty? && kwargs.empty?
          parse_build_body(package, block_statements(statement[2]))
          next
        end

        directive, args, kwargs = parse_call(statement)
        unless PACKAGE_DIRECTIVES.include?(directive)
          raise_error("unknown nuclei directive '#{directive}'")
        end

        apply_package_directive(package, directive, args, kwargs)
      end
    end

    def parse_build_body(package, statements)
      context = BuildContext.new(package, path: @path)

      statements.each do |statement|
        raise_error("nested blocks are not allowed in build") if node_type(statement) == :method_add_block

        directive, args, kwargs = parse_call(statement)
        unless BUILD_DIRECTIVES.include?(directive)
          raise_error("unknown build directive '#{directive}'")
        end
        raise_error("build directive '#{directive}' does not accept keywords") unless kwargs.empty?

        context.__send__(directive, *args)
      end
    end

    def apply_package_directive(package, directive, args, kwargs)
      @package_dsl ||= NucleiDSL.new(path: @path, strict: @strict)
      dsl = @package_dsl
      dsl.__attach_package__(package)
      dsl.__send__(directive, *args, **kwargs)
    rescue ArgumentError => e
      raise_error("invalid arguments for '#{directive}': #{e.message}")
    end

    def parse_call(node)
      type = node_type(node)
      case type
      when :command
        name = token_value(node[1], :@ident)
        args, kwargs = parse_args(node[2])
      when :method_add_arg
        name = parse_callable_name(node[1])
        args, kwargs = parse_args(node[2])
      when :vcall, :fcall
        name = token_value(node[1], :@ident)
        args = []
        kwargs = {}
      else
        raise_error("unsupported expression #{type.inspect}")
      end

      [name, args, kwargs]
    end

    def parse_callable_name(node)
      case node_type(node)
      when :fcall, :vcall
        token_value(node[1], :@ident)
      else
        raise_error("method receivers are not allowed")
      end
    end

    def parse_args(node)
      return [[], {}] if node.nil? || node == []

      values = case node_type(node)
               when :arg_paren
                 node[1] ? argument_nodes(node[1]) : []
               when :args_add_block
                 raise_error("block forwarding is not allowed") unless node[2] == false
                 Array(node[1])
               else
                 argument_nodes(node)
               end

      kwargs = {}
      if values.last && node_type(values.last) == :bare_assoc_hash
        kwargs = literal(values.pop)
      end
      [values.map { |value| literal(value) }, kwargs]
    end

    def argument_nodes(node)
      case node_type(node)
      when :args_add_block
        raise_error("block forwarding is not allowed") unless node[2] == false
        Array(node[1])
      when :args_add
        argument_nodes(node[1]) + [node[2]]
      when :args_new
        []
      else
        raise_error("unsupported argument list #{node_type(node).inspect}")
      end
    end

    def literal(node)
      type = node_type(node)
      case type
      when :string_literal
        string_literal(node)
      when :symbol_literal
        symbol_literal(node)
      when :array
        array_literal(node)
      when :hash, :bare_assoc_hash
        hash_literal(node)
      when :var_ref
        keyword_literal(node[1])
      when :@int
        Integer(node[1], 10)
      when :@float
        Float(node[1])
      when :unary
        unary_literal(node)
      else
        raise_error("only literal recipe arguments are allowed (got #{type.inspect})")
      end
    end

    def string_literal(node)
      content = node[1]
      return "" if content.nil? || content == [:string_content]
      raise_error("invalid string literal") unless node_type(content) == :string_content

      parts = content[1..]
      unless parts.all? { |part| node_type(part) == :@tstring_content }
        raise_error("string interpolation is not allowed in recipes")
      end
      parts.map { |part| part[1] }.join
    end

    def symbol_literal(node)
      symbol = node.dig(1, 1)
      type = node_type(symbol)
      unless %i[@ident @op @const @kw].include?(type)
        raise_error("dynamic symbols are not allowed")
      end
      symbol[1].to_sym
    end

    def array_literal(node)
      body = node[1]
      return [] if body.nil?

      nodes = node_type(body) == :args_add_block ? argument_nodes(body) : Array(body)
      nodes.map { |entry| literal(entry) }
    end

    def hash_literal(node)
      assoc_list = node_type(node) == :hash ? node[1] : node
      return {} if assoc_list.nil?

      entries = if node_type(assoc_list) == :assoclist_from_args
                  Array(assoc_list[1])
                elsif node_type(assoc_list) == :bare_assoc_hash
                  Array(assoc_list[1])
                else
                  raise_error("invalid hash literal")
                end

      entries.each_with_object({}) do |entry, result|
        raise_error("hash splats are not allowed") unless node_type(entry) == :assoc_new
        key = hash_key(entry[1])
        result[key] = literal(entry[2])
      end
    end

    def hash_key(node)
      case node_type(node)
      when :@label
        node[1].delete_suffix(":").to_sym
      when :symbol_literal
        symbol_literal(node)
      when :string_literal
        string_literal(node)
      else
        raise_error("hash keys must be labels, symbols, or strings")
      end
    end

    def keyword_literal(node)
      raise_error("invalid keyword literal") unless node_type(node) == :@kw

      case node[1]
      when "true" then true
      when "false" then false
      when "nil" then nil
      else raise_error("unsupported keyword #{node[1].inspect}")
      end
    end

    def unary_literal(node)
      op = node[1]
      value = literal(node[2])
      return -value if op == :-@ && value.is_a?(Numeric)
      return value if op == :+@ && value.is_a?(Numeric)

      raise_error("unsupported unary expression")
    end

    def program_statements(tree)
      raise_error("invalid recipe document") unless node_type(tree) == :program
      Array(tree[1]).reject { |statement| statement.nil? || node_type(statement) == :void_stmt }
    end

    def block_statements(block)
      raise_error("missing do block") unless %i[do_block brace_block].include?(node_type(block))
      body = block[2]
      raise_error("invalid block body") unless node_type(body) == :bodystmt
      raise_error("rescue/else/ensure are not allowed") unless body[2..4].all?(&:nil?)

      Array(body[1]).reject { |statement| statement.nil? || node_type(statement) == :void_stmt }
    end

    def token_value(node, expected_type)
      raise_error("expected #{expected_type}") unless node_type(node) == expected_type
      node[1]
    end

    def node_type(node)
      node.is_a?(Array) ? node[0] : nil
    end

    def raise_error(message)
      raise ParseError, "Unsafe or invalid nuclei recipe #{@path}: #{message}"
    end
  end
end
