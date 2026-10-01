# frozen_string_literal: true

module AimHelm
  module Catalog
    # One catalog row. Prices are per million tokens; `cost` scales a Usage down accordingly.
    # `long_context` holds the rates billed for the whole call once its prompt passes `above`.
    class Model < Dry::Struct
      attribute :cache_write, Types::Coercible::Float
      attribute :cached_input, Types::Coercible::Float
      attribute :context, Types::Coercible::Integer
      attribute :id, Types::String
      attribute :input, Types::Coercible::Float
      attribute :max_output, Types::Coercible::Integer
      attribute :output, Types::Coercible::Float
      attribute :provider, Types::Coercible::Symbol
      attribute :reasoning_effort, Types::Bool
      attribute :vision, Types::Bool

      attribute? :long_context do
        transform_keys(&:to_sym)

        attribute :above, Types::Coercible::Integer
        attribute :cache_write, Types::Coercible::Float
        attribute :cached_input, Types::Coercible::Float
        attribute :input, Types::Coercible::Float
        attribute :output, Types::Coercible::Float
      end

      def cost(usage)
        rates = long_context && usage.prompt_tokens > long_context.above ? long_context : self

        ((usage.input_tokens * rates.input) +
         (usage.output_tokens * rates.output) +
         (usage.cached_input_tokens * rates.cached_input) +
         (usage.cache_write_tokens * rates.cache_write)) / 1_000_000.0
      end
    end
  end
end
