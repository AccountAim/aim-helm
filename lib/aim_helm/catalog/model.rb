# frozen_string_literal: true

module AimHelm
  module Catalog
    # One catalog row. Prices are per million tokens; `cost` scales a Usage down accordingly.
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

      def cost(usage)
        ((usage.input_tokens * input) +
         (usage.output_tokens * output) +
         (usage.cached_input_tokens * cached_input) +
         (usage.cache_write_tokens * cache_write)) / 1_000_000.0
      end
    end
  end
end
