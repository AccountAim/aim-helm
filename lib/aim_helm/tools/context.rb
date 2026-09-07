# frozen_string_literal: true

module AimHelm
  module Tools
    # Tool-call context: application state, execution IDs, a call-scoped event sink,
    # and a cooperative stop check.
    class Context < Dry::Struct
      attribute :app, Types.Instance(Object).optional.default(nil)
      attribute :call_id, Types::String
      attribute :events, Types.Interface(:call)
      attribute :run_id, Types::String
      attribute :session, Types.Instance(AimHelm::Session)
      attribute :turn_id, Types::String

      def session_id = session.id
      def idempotency_key = call_id
      def broadcast(type, **payload) = events.call(type:, **payload)
      def stop_requested? = session.stop_requested?(run_id:)
    end
  end
end
