# frozen_string_literal: true

module AimHelm
  # One agent conversation as an append-only entry log over a Store. Status, the pending run,
  # open approvals, and child sessions are all folded from those entries rather than stored; only
  # `interrupted` comes from the store's lease heartbeat. `append!` raises AppendAnomaly when a
  # keyed entry already exists, while plain `append` returns nil and leaves the choice to callers.
  class Session < Dry::Struct
    ID = Types::String.default { SecureRandom.uuid_v7 }
    MAX_WAIT_TIMEOUT = 300
    WAIT_INTERVAL = 0.25
    WAIT_ACTIVITY_INTERVAL = 30
    LIVE_STATUSES = %i[queued running awaiting_approval awaiting_subagent interrupted].freeze
    TERMINAL_STATUSES = %i[completed failed stopped].freeze

    # Entry kind => the status it moves the session to. status_from folds entries in order, so the
    # last mapped kind wins and unlisted kinds leave the status unchanged; `terminal` is not here
    # because status_for reads its outcome from the payload.
    STATUS_BY_KIND = {
      "user" => :queued,
      "run_record" => :queued,
      "assistant" => :running,
      "tool_call" => :running,
      "tool_started" => :running,
      "tool_result" => :running,
      "approval_request" => :awaiting_approval,
      "approval_decision" => :queued,
      "report_delivered" => :queued,
      "spawn_record" => :running,
      "subagent" => :running,
      "stop_request" => :queued,
      "usage" => :running,
    }.freeze

    attribute(:config, Types.Instance(AimHelm::Config).default { AimHelm.config })
    attribute :id, ID
    attribute :store, Types::Store

    def append(kind, payload, key: nil, run_id: nil, turn_id: nil)
      store.append(id, kind, payload, key:, run_id:, turn_id:)
    end

    def append!(kind, payload, key: nil, run_id: nil, turn_id: nil)
      append(kind, payload, key:, run_id:, turn_id:) ||
        raise(AppendAnomaly, "duplicate #{kind} append for session #{id}")
    rescue StandardError => e
      config.telemetry.call(
        :append_anomaly,
        count: 1,
        session_id: id,
        kind: kind.to_s,
        error_class: e.class.name,
      )
      raise
    end

    def entries(after_id: nil) = store.entries(id, after_id:)
    def usage = Usage.new(self)
    def transaction(&) = store.transaction(&)

    def status
      durable = self.class.status_from(entries)
      return durable unless store.respond_to?(:interrupted?)
      return :interrupted if store.interrupted?(id, status: durable)

      durable
    end

    def pending_run_id = self.class.pending_run_id(entries)
    def pending_messages(entries: self.entries) = queued_messages.pending(entries:)
    def pending_message_content(entries: self.entries) = queued_messages.content(entries:)
    def fold_messages(run_id:, entries: self.entries) = queued_messages.fold(run_id:, entries:)

    def stop_requested?(run_id:, entries: self.entries)
      entries.any? { it.kind == "stop_request" && it.run_id == run_id }
    end

    def open_approvals(run_id:)
      state = Approvals.new(entries:, run_id:)
      state.unresolved_calls.filter_map { state.approval_for(it) }
    end

    def pending_approvals
      run_id = pending_run_id
      run_id ? open_approvals(run_id:) : []
    end

    def approve(call_id, by:, note: nil, rule: nil)
      decide(call_id:, verdict: :approve, by:, note:, rule:)
    end

    def deny(call_id, by:, reason: nil)
      decide(call_id:, verdict: :deny, by:, note: reason, rule: nil)
    end

    def stop(reason: nil)
      run_id = Control.new(session: self).stop(reason:)
      subagents.each { it.stop(reason:) } if run_id
      config.advance&.call(id) if run_id
      run_id
    end

    def wait(
      timeout: MAX_WAIT_TIMEOUT,
      interval: WAIT_INTERVAL,
      activity_interval: WAIT_ACTIVITY_INTERVAL,
      &activity
    )
      unless timeout.between?(1, MAX_WAIT_TIMEOUT)
        raise ArgumentError, "timeout must be between 1 and #{MAX_WAIT_TIMEOUT} seconds"
      end

      deadline = monotonic_time + timeout
      next_activity_at = monotonic_time + activity_interval

      while LIVE_STATUSES.include?(status) && (now = monotonic_time) < deadline
        if now >= next_activity_at
          activity&.call
          next_activity_at = now + activity_interval
        end

        sleep(interval)
      end

      self
    end

    def transcript = entries.map(&:dump)
    def spend = Budget::Spend.from(entries)

    def subagents
      entries.filter_map do
        next unless it.kind == "subagent"

        child_id = it.payload.fetch("id")
        child = new(id: child_id)
        Subagent::Handle.new(
          id: child_id,
          name: it.payload.fetch("name"),
          task: it.payload.fetch("task"),
          session: child,
        )
      end.uniq(&:id)
    end

    class << self
      def pending_run_id(entries)
        terminal_runs = entries.filter_map do
          it.run_id if it.kind == "terminal"
        end.to_set
        entries.find do
          it.kind == "user" && !terminal_runs.include?(it.run_id)
        end&.run_id
      end

      def status_from(entries)
        return :empty if entries.empty?

        status = entries.reduce(:queued) { |current, entry| status_after(current, entry) }
        return status if TERMINAL_STATUSES.include?(status)
        return :awaiting_approval if awaiting_approval?(entries)
        return :awaiting_subagent if awaiting_subagent?(entries)

        status
      end

      def awaiting_subagent?(entries) = Subagents::Record.delegated_call_ids(entries).any?

      def status_after(current, entry)
        status_for(entry) || current.to_sym
      end

      def status_for(entry)
        if entry.kind == "terminal"
          outcome = entry.payload.fetch("outcome").to_sym
          return outcome == :done ? :completed : outcome
        end

        # Compaction usage lands after the run's terminal entry; mapping it would reopen the run.
        return if entry.kind == "usage" && entry.payload["purpose"] == "compaction"

        STATUS_BY_KIND[entry.kind]
      end

      private

      def awaiting_approval?(entries)
        run_id = pending_run_id(entries)
        return false unless run_id

        run_entries = entries.select { it.run_id == run_id }
        requests = call_ids(run_entries, "approval_request")
        decisions = call_ids(run_entries, "approval_decision")
        results = call_ids(run_entries, "tool_result")
        (requests - decisions - results).any?
      end

      def call_ids(entries, kind)
        entries.filter_map {  it.payload["call_id"] if it.kind == kind }.to_set
      end
    end

    private

    def decide(call_id:, verdict:, by:, note:, rule:)
      entry = Control.new(session: self).decide(
        call_id:,
        verdict:,
        decided_by: by,
        note:,
        rule:,
      )

      if entry
        approval = open_approvals(run_id: entry.run_id).find { it.call_id == call_id }
        broadcast_decision(approval, verdict)
        config.advance&.call(id)
      end

      entry
    end

    def broadcast_decision(approval, verdict)
      return unless config.broadcast

      type = verdict == :approve ? :"tool.approved" : :"tool.denied"
      event = approval.event(type).with(
        session_id: id,
        run_id: approval.run_id,
        turn_id: approval.turn_id,
      )
      context = store.context(id) if store.respond_to?(:context)
      config.broadcast.call(Events::Delivery.new(event:, session: self, context:))
    end

    def queued_messages = @queued_messages ||= QueuedMessages.new(session: self)
    def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
