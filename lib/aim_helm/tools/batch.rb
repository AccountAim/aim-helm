# frozen_string_literal: true

module AimHelm
  module Tools
    # Drives one turn's tool calls off the log: appends the calls, sorts each unresolved one into
    # immediate, rule-approved, human-pending, or denied, and appends a result for every call.
    # `resume` re-reads the same entries after a decision lands, so a turn can park and continue.
    class Batch < Dry::Struct
      INTERRUPTED = "interrupted — may or may not have completed"
      NO_AUTHORIZATION = ->(**) {}.freeze
      NO_INTERRUPTED_TOOL_HANDLER = ->(**) {}.freeze

      class Outcome < Dry::Struct
        attribute :parked, Types::Array.of(Types::String).default([].freeze)
        attribute :pending, Types::Array.of(Types.Instance(AimHelm::Session::Approval)).default([].freeze)

        def awaiting_approval? = pending.any?
        def awaiting_subagent? = parked.any?
        def open? = awaiting_approval? || awaiting_subagent?
      end

      class Buckets < Dry::Struct
        LIST = Types::Array.default { [] }

        attribute :approved, LIST
        attribute :denied, LIST
        attribute :immediate, LIST
        attribute :pending, LIST
        attribute :requests, LIST
      end

      attribute :app, Types.Instance(Object).optional.default(nil)
      attribute :authorize, Types.Interface(:call)
      attribute :emit, Types.Interface(:call)
      attribute :executor, Types.Interface(:prepare, :call)
      attribute :on_interrupted_tool, Types.Interface(:call)
      attribute :run_id, Types::String
      attribute :session, Types.Instance(AimHelm::Session)
      attribute :turn_id, Types::String

      def start(tool_calls, entries:)
        calls = tool_calls.map { append_call(it) }
        advance(entries: entries + calls)
      end

      def resume(entries:) = advance(entries:)

      private

      def advance(entries:)
        state = Session::Approvals.new(entries:, run_id:)
        buckets = Buckets.new
        parked = []

        delegated = Subagents::Record.delegated_call_ids(entries)

        state.unresolved_calls.each do
          # Its child answers this one; the turn stays parked rather than recovering it.
          next parked << it.fetch("id") if delegated.include?(it.fetch("id"))

          # Started with no result: the process died mid-call and the side effect is unknown.
          if state.started?(it)
            on_interrupted_tool.call(tool_call: it, entries:)
            append_result(interrupted_result(it))
            next
          end

          approval = state.approval_for(it)

          if approval
            prepared = validate(approval, it)
            sort_decided(it, approval, prepared, buckets)
          else
            sort_new(it, buckets)
          end
        end

        parked.concat(execute(buckets.immediate))
        buckets.requests.each { append_approval(it) }
        # Human-approved calls settle only after the whole gated batch has a decision.
        return Outcome.new(pending: buckets.pending, parked:) if buckets.pending.any?

        buckets.denied.each { append_result(denied_result(it)) }
        parked.concat(execute(buckets.approved))
        Outcome.new(parked:)
      end

      def sort_new(tool_call, buckets)
        prepared = prepare(tool_call)
        return buckets.immediate << tool_call unless prepared

        return buckets.immediate << tool_call unless prepared.approval_required?(
          context: tool_context(prepared),
        )

        approval = prepared.approval(run_id:, turn_id:)
        rule = authorize.call(tool: prepared.tool, arguments: prepared.arguments, app:)

        if rule
          append_approval(approval)
          append_decision(
            approval,
            verdict: :approve,
            source: :rule,
            decided_by: rule.to_s,
            rule: rule.to_s,
          )
          buckets.immediate << tool_call
        else
          buckets.pending << approval
          buckets.requests << approval
        end
      end

      def sort_decided(tool_call, approval, prepared, buckets)
        unless approval.decided?
          rule = authorize.call(tool: prepared.tool, arguments: prepared.arguments, app:)

          if rule
            append_decision(
              approval,
              verdict: :approve,
              source: :rule,
              decided_by: rule.to_s,
              rule: rule.to_s,
            )
            return buckets.immediate << tool_call
          end

          return buckets.pending << approval
        end

        return buckets.denied << approval unless approval.approved?

        target = approval.decision.source == :rule ? buckets.immediate : buckets.approved
        target << tool_call
      end

      def validate(approval, tool_call)
        unless approval.tool_call == tool_call.slice("id", "name", "arguments")
          raise TamperedRecordError, "approval #{approval.call_id} does not match its tool call"
        end

        prepared = executor.prepare(tool_call)

        unless approval.tool_name == (prepared.tool.identifier || prepared.tool.name)
          raise TamperedRecordError, "approval #{approval.call_id} resolves to a different tool"
        end

        # Called for its raise: a gate that now errors makes the approval unexecutable.
        prepared.approval_required?(context: tool_context(prepared))
        prepared
      rescue ArgumentError, KeyError => e
        message = "approval #{approval.call_id} is no longer executable: #{e.message}"
        raise ConfigurationError, message
      end

      def prepare(tool_call)
        executor.prepare(tool_call)
      rescue ArgumentError, KeyError
        nil
      end

      def tool_context(prepared)
        Context.new(
          session:,
          events: Broadcaster.new(sink: emit, call_id: prepared.call_id),
          app:,
          run_id:,
          turn_id:,
          call_id: prepared.call_id,
        )
      end

      # Parked calls carry no result yet; their ids ride out so the run can wait on them.
      def execute(tool_calls)
        results = executor.call(tool_calls)
        results.reject {  it[:parked] }.each { append_result(it) }
        results.select {  it[:parked] }.map { it.fetch(:call_id) }
      end

      def append_call(tool_call)
        append!(:tool_call, tool_call, key: "call:#{tool_call.fetch("id")}")
      end

      def append_approval(approval)
        append!(:approval_request, approval.dump, key: "approval:#{approval.call_id}")
        emit.call(approval.event(:"tool.approval"))
      end

      def append_decision(approval, verdict:, source:, decided_by:, rule: nil)
        decision = Session::Approval::Decision.new(verdict:, source:, decided_by:, rule:)
        append!(:approval_decision, decision.dump.merge("call_id" => approval.call_id),
                key: "decision:#{approval.call_id}")
        type = verdict == :approve ? :"tool.approved" : :"tool.denied"
        emit.call(approval.event(type))
      end

      def append_result(result)
        append!(:tool_result, result, key: "result:#{result.fetch(:call_id)}")
      end

      def append!(kind, payload, key: nil)
        session.append!(kind, payload, key:, run_id:, turn_id:)
      end

      def interrupted_result(tool_call)
        {
          call_id: tool_call.fetch("id"),
          output: INTERRUPTED,
          error: true,
        }
      end

      def denied_result(approval)
        {
          call_id: approval.call_id,
          output: "The user denied this tool call.",
          error: true,
        }
      end
    end
  end
end
