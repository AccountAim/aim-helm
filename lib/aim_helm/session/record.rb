# frozen_string_literal: true

module AimHelm
  class Session
    # One durable transcript entry — the row shape every Store returns. `id` orders the log and
    # drives `after_id` reads; `key` is the uniqueness key that makes an append idempotent.
    class Record < Dry::Struct
      attribute :created_at, Types.Instance(Time)
      attribute :id, Types::Coercible::Integer
      attribute :kind, Types::String
      attribute :payload, Types::JsonObject
      attribute :session_id, Types::String
      attribute :key, Types::String.optional.default(nil)
      attribute :run_id, Types::String.optional.default(nil)
      attribute :turn_id, Types::String.optional.default(nil)

      def self.deserialize(attributes)
        values = attributes.transform_keys(&:to_sym)
        values[:created_at] = Time.iso8601(values.fetch(:created_at))
        new(**values)
      end

      def dump = to_h.merge(created_at: created_at.iso8601(6))
    end
  end
end
