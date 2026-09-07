# frozen_string_literal: true

# Port of dry-rb/dry-schema#518, unmerged as of dry-schema 1.16: a `.documentation` macro,
# dry-types `meta(json_schema:)` propagation, and default-value output for the json_schema
# extension. Kept close to the PR diff; delete once the PR ships in a release.

module Dry
  module Schema
    module JSONSchema
      module SchemaMethods
        # @api public
        def json_schema(loose: false)
          compiler = SchemaCompiler.new(root: true, loose: loose, type_schema: type_schema)
          compiler.call(to_ast)
          compiler.to_hash
        end
      end

      module MacroMethods
        # Attach JSON Schema documentation metadata to this key
        #
        # @example
        #   required(:email).filled(:string).documentation(description: "User email")
        #
        # @api public
        def documentation(title: nil, description: nil, examples: nil, example: nil,
                          deprecated: false)
          if schema_dsl.types[name].is_a?(Dry::Types::AnyClass)
            raise ::Dry::Schema::InvalidSchemaError,
                  ".documentation must be called after a type is set (e.g. after .filled or .value)"
          end

          attrs = {
            title: title, description: description,
            examples: examples, example: example,
            deprecated: deprecated || nil
          }.compact
          current = schema_dsl.types[name].meta[:json_schema] || {}
          schema_dsl.types[name] = schema_dsl.types[name].meta(json_schema: current.merge(attrs))
          self
        end
      end

      class SchemaCompiler
        # @api private
        def initialize(root: false, loose: false, type_schema: nil)
          @keys = EMPTY_HASH.dup
          @required = Set.new
          @root = root
          @loose = loose
          @type_schema = type_schema
        end

        # @api private
        def visit_set(node, opts = EMPTY_HASH)
          target = if (key = opts[:key])
                     self.class.new(loose: loose?,
                                    type_schema: child_type_schema(
                                      key, opts[:member]
                                    ))
                   else
                     self
                   end

          node.map {  target.visit(it, opts.except(:member)) }

          return unless key

          target_info = opts[:member] ? { items: target.to_h } : target.to_h
          type = opts[:member] ? "array" : "object"

          merge_opts!(keys[key], { type: type, **target_info })
        end

        # @api private
        def visit_key(node, opts = EMPTY_HASH)
          name, rest = node

          if opts.fetch(:required, true)
            required << name.to_s
          else
            opts.delete(:required)
          end

          visit(rest, opts.merge(key: name))

          return unless @type_schema

          begin
            key_type = @type_schema.key(name)
            type_meta = key_type.meta[:json_schema]

            if type_meta
              sanitized = type_meta.dup

              if sanitized.key?(:example)
                sanitized[:example] =
                  serialize_json_value(sanitized[:example])
              end

              if sanitized.key?(:examples)
                sanitized[:examples] = sanitized[:examples]&.map do
                  serialize_json_value(it)
                end
              end

              keys[name].merge!(sanitized)
            end

            default = extract_default(key_type)
            keys[name][:default] = default unless default.equal?(Undefined)
          rescue KeyError
            # key not found in type_schema, skip
          end
        end

        private

        def extract_default(type)
          t = type

          while t
            return serialize_json_value(t.value) if t.is_a?(Dry::Types::Default)

            t = t.respond_to?(:type) ? t.type : nil
          end

          Undefined
        end

        def serialize_json_value(value)
          case value
          when ::String, ::Integer, ::Float, ::TrueClass, ::FalseClass, ::NilClass
            value
          when ::Symbol
            value.to_s
          when ::BigDecimal
            value.to_f
          when ::Date, ::Time
            value.iso8601
          when ::Array
            items = value.map { serialize_json_value(it) }
            return Undefined if items.any? { it.equal?(Undefined) }

            items
          when ::Hash
            result = {}

            value.each do |k, v|
              converted_key = serialize_json_value(k)
              converted_val = serialize_json_value(v)
              return Undefined if converted_key.equal?(Undefined) || converted_val.equal?(Undefined)

              result[converted_key] = converted_val
            end

            result
          else
            Undefined
          end
        end

        def child_type_schema(key, member)
          return unless @type_schema.respond_to?(:key)

          key_type = @type_schema.key(key).type
          return key_type unless member

          # For arrays: unwrap Lax -> Array::Member -> member (the element hash schema)
          inner = key_type.respond_to?(:type) ? key_type.type : key_type
          inner.respond_to?(:member) ? inner.member : nil
        rescue KeyError
          nil
        end
      end
    end

    Macros::Core.include(JSONSchema::MacroMethods)
  end
end
