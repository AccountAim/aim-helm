# frozen_string_literal: true

module AimHelm
  class Session
    # One approval-gated tool call and its decision, if made. `name` is the call name the model
    # emitted, `tool_name` the registered identifier Batch re-resolves before running, and `title`
    # the tool's human label.
    class Approval < Dry::Struct
      class Decision < Dry::Struct
        attribute :decided_by, Types::String
        attribute :note, Types::String.optional.default(nil)
        attribute :rule, Types::String.optional.default(nil)
        attribute :source, Types::Coercible::Symbol.enum(:human, :rule)
        attribute :verdict, Types::Coercible::Symbol.enum(:approve, :deny)

        def approved? = verdict == :approve
        def dump = Types::JsonObject[to_h.compact]
      end

      attribute :arguments, Types::JsonObject
      attribute :call_id, Types::String
      attribute :decision, Types.Instance(Decision).optional.default(nil)
      attribute :name, Types::String
      attribute :run_id, Types::String
      attribute :title, Types::String
      attribute :tool_name, Types::String
      attribute :turn_id, Types::String

      def self.from(entry, decision: nil)
        payload = entry.payload
        new(
          call_id: payload.fetch("call_id"),
          name: payload.fetch("name"),
          tool_name: payload.fetch("tool_name"),
          arguments: payload.fetch("arguments"),
          title: payload.fetch("title"),
          run_id: entry.run_id,
          turn_id: entry.turn_id,
          decision:,
        )
      end

      def decided? = !decision.nil?
      def approved? = decision&.approved? || false

      def event(type)
        Event.build(type:, call_id:, name:, arguments:, title:)
      end

      def dump
        Types::JsonObject[
          call_id:,
          name:,
          tool_name:,
          arguments:,
          title:,
        ]
      end

      def tool_call
        {
          "id" => call_id,
          "name" => name,
          "arguments" => arguments,
        }
      end
    end
  end
end
