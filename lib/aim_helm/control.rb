# frozen_string_literal: true

module AimHelm
  # Lifecycle writes for one session: start and continue runs, queue messages, request a stop,
  # record an approval decision, and fail a run. Every append carries a key, so a second writer
  # collides instead of duplicating — `decide` and `fail_run` read the nil return as a loss and
  # reconcile, while run minting uses append! and treats a collision as an anomaly.
  class Control < Dry::Struct
    # Statuses whose session should be dispatched after a message lands. awaiting_approval is
    # excluded because the approval decision dispatches on its own.
    DISPATCHABLE = (Session::LIVE_STATUSES - [:awaiting_approval] + [:completed]).freeze

    attribute :session, Types.Instance(AimHelm::Session)

    def read(tail: 20)
      {
        id: session.id,
        status: session.status,
        transcript: session.entries.last(tail).map(&:dump),
      }
    end

    def start(prompt:, record:, run_id: SecureRandom.uuid_v7)
      session.append!(:run_record, record.dump, key: "run:#{run_id}", run_id:)
      session.append!(:user, user_payload(prompt), key: "user:#{run_id}", run_id:)
      run_id
    end

    def start_subagent(record:)
      session.append!(
        :spawn_record,
        record.dump,
        key: "spawn:#{record.run_id}",
        run_id: record.run_id,
      )
      start(prompt: record.task, record: record.options, run_id: record.run_id)
    end

    def continue_subagent(record:)
      status = session.status
      raise ArgumentError, "session is #{status}" unless Session::TERMINAL_STATUSES.include?(status)

      start_subagent(record:)
    end

    def queue_message(content:, type: :message, key: nil, **metadata)
      Session::QueuedMessages.new(session:).append(content:, type:, key:, **metadata)
    end

    def deliver(content:, type: :message, key: nil, **metadata)
      current = session.status

      # A subagent report is the one message a finished session accepts: it starts the next run.
      if Session::TERMINAL_STATUSES.include?(current) && type != :report
        raise ArgumentError, "session is #{current}; continue it with a new task"
      end

      queue_message(content:, type:, key:, **metadata)
      advance_pending(current)
    end

    def stop(reason: nil)
      run_id = session.pending_run_id
      return unless run_id

      session.append(:stop_request, { reason: }.compact, key: "stop:#{run_id}", run_id:)
      run_id
    end

    def decide(call_id:, verdict:, decided_by:, rule: nil, note: nil)
      run_id = session.pending_run_id or raise ConfigurationError, "session has no pending run"
      approval = session.open_approvals(run_id:).find { it.call_id == call_id }
      raise ConfigurationError, "no open approval for #{call_id.inspect}" unless approval

      decision = Session::Approval::Decision.new(verdict:, source: :human, decided_by:, rule:,
                                                 note:)

      if approval.decided?
        return if approval.decision == decision

        raise ConfigurationError, "approval for #{call_id.inspect} has already been decided"
      end

      entry = session.append(
        :approval_decision,
        decision.dump.merge("call_id" => call_id),
        key: "decision:#{call_id}",
        run_id: approval.run_id,
        turn_id: approval.turn_id,
      )
      return entry if entry

      winner = decision_entry(call_id)
      return if decision_from(winner) == decision

      raise ConfigurationError, "approval for #{call_id.inspect} has already been decided"
    end

    def fail_run(run_id:, reason:, error:)
      payload = { outcome: :failed, reason:, error: error.message }
      entry = session.append(:terminal, payload, key: "terminal:#{run_id}", run_id:)
      return unless entry

      Event.build(type: :"run.failed", reason:, error: error.message).with(
        session_id: session.id,
        run_id:,
      )
    end

    # A parked run — held by an approval, or by a delegated child still working — cannot take
    # new input: its open tool call has to be answered before the next user turn. Callers should
    # keep the composer shut while the session is live rather than let this surface as a 500.
    def continue(prompt:, record: nil, run_id: SecureRandom.uuid_v7)
      status = session.status
      raise ArgumentError, "session is #{status}" unless Session::TERMINAL_STATUSES.include?(status)

      record ||= Agent::Record.latest(session.entries)
      carry_spawn_record(run_id:, task: prompt, options: record)
      start(prompt:, record:, run_id:)
    end

    def continue_queued(
      run_id: SecureRandom.uuid_v7,
      record: Agent::Record.latest(session.entries)
    )
      raise ArgumentError, "session is #{session.status}" unless session.status == :completed

      carry_spawn_record(
        run_id:,
        task: session.pending_message_content,
        options: record,
      )
      session.append!(
        :run_record,
        record.dump,
        key: "run:#{run_id}",
        run_id:,
      )
      session.fold_messages(run_id:)
      run_id
    end

    private

    def user_payload(prompt) = { content: Message.user(prompt).content }

    def advance_pending(status)
      return unless session.pending_messages.any? || session.pending_run_id

      if status == :completed && session.pending_messages.any?
        run_id = SecureRandom.uuid_v7

        session.transaction do
          continue_queued(run_id:)
        end
      end

      session.config.advance&.call(session.id) if DISPATCHABLE.include?(status)
    end

    # A subagent's every run needs its own spawn record: verification fetches the grant by
    # run_id. The continuation is always background — nothing is blocking on it, so the child
    # reports back through ReportDelivery.
    def carry_spawn_record(run_id:, task:, options:)
      entry = session.entries.reverse_each.find { it.kind == "spawn_record" }
      return unless entry

      record = Subagents::Record.deserialize(entry.payload)
      continued = record.with(run_id:, task:, mode: :background, options:)
      session.append!(:spawn_record, continued.dump, key: "spawn:#{run_id}", run_id:)
    end

    def decision_entry(call_id)
      session.entries.find do
        it.kind == "approval_decision" && it.payload["call_id"] == call_id
      end
    end

    def decision_from(entry)
      payload = entry.payload.except("call_id").transform_keys(&:to_sym)
      Session::Approval::Decision.new(**payload)
    end
  end
end
