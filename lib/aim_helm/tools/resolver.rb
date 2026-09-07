# frozen_string_literal: true

module AimHelm
  module Tools
    # Maps a durable tool identifier ("reports/lookup") to the Tool constant of the same name in
    # a namespace (Reports::Lookup), so a run record can name its tools instead of serializing
    # them. Wired as config.tools; without it a turn restored from the log cannot rebuild them.
    class Resolver < Dry::Struct
      attribute :namespace, Types.Instance(Module)

      def identifiers(tools)
        tools.map do
          identifier = it.is_a?(String) ? it : it.identifier
          raise ArgumentError, "durable tools require registered identifiers" unless identifier

          resolve(identifier)
          identifier
        end
      end

      def resolve(identifier)
        constant = identifier.split("/").reduce(namespace) do |parent, segment|
          name = camelize(segment)

          unless parent.const_defined?(name, false)
            raise ConfigurationError, "unknown registered tool #{identifier.inspect}"
          end

          parent.const_get(name, false)
        end
        return constant if constant.is_a?(Tool)

        raise ConfigurationError, "registered tool #{identifier.inspect} is not a AimHelm::Tool"
      end

      private

      def camelize(segment) = segment.split("_").map!(&:capitalize).join
    end
  end
end
