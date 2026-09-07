# frozen_string_literal: true

module AimHelm
  class Session
    # Approval state for one run, derived from a single transcript snapshot: which tool calls are
    # unresolved, which already started, and which requests carry a decision. Every lookup is
    # memoized, so build a new instance after appending to the session.
    class Approvals < Dry::Struct
      attribute :entries, Types::Array.of(Types.Instance(AimHelm::Session::Record))
      attribute :run_id, Types::String

      def unresolved_calls
        calls.reject { results.include?(it.fetch("id")) }
      end

      def started?(tool_call) = starts.include?(tool_call.fetch("id"))

      def approval_for(tool_call)
        entry = requests[tool_call.fetch("id")]
        return unless entry

        Approval.from(entry, decision: decisions[tool_call.fetch("id")])
      end

      private

      def transcript = @transcript ||= entries.select { it.run_id == run_id }
      def calls = @calls ||= payloads("tool_call")
      def starts = @starts ||= payloads("tool_started").to_set { it.fetch("call_id") }
      def results = @results ||= payloads("tool_result").to_set { it.fetch("call_id") }

      def requests
        @requests ||= records("approval_request").to_h do
          [it.payload.fetch("call_id"), it]
        end
      end

      def decisions
        @decisions ||= payloads("approval_decision").to_h do
          decision = Approval::Decision.new(**it.except("call_id").transform_keys(&:to_sym))
          [it.fetch("call_id"), decision]
        end
      end

      def records(kind) = transcript.select { it.kind == kind }
      def payloads(kind) = records(kind).map(&:payload)
    end
  end
end
