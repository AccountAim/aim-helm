# frozen_string_literal: true

module AimHelm
  class Execution
    # Runs one leased run end to end: picks the run id — the pending run, or one folded from
    # queued messages — then resumes the root run or a verified subagent run, returning nil when
    # nothing is left to run. `finish` closes the event sink before releasing the lease, so events
    # flush while ownership still holds, then re-dispatches when messages arrived mid-run.
    # Entered from Execution#advance with the Binding the store issued at claim time.
    class Driver < Dry::Struct
      include Dry::Monads[:result]

      attribute :binding, Types.Instance(Binding)
      attribute :foreground, Types.Interface(:call).optional.default(nil)
      attribute :options, Types.Instance(AimHelm::Agent)

      attr_reader :report

      def call
        @session = binding.session
        @events = leased_events

        execute do
          @run_id = next_run_id
          next unless @run_id

          binding.subagent? ? resume_subagent : resume_root
        end
      ensure
        finish
      end

      private

      def execute
        yield
      rescue TamperedRecordError, ConfigurationError => e
        fail_run(:invalid_run_record, e)
        raise
      rescue LeaseLostError, TransientError => e
        # A transient failure only terminates the turn on the last attempt, and a lost lease never
        # does: another worker owns the turn now.
        fail_run(:transient_error, e) if binding.final_attempt && !e.is_a?(LeaseLostError)
        raise
      rescue StandardError => e
        fail_run(:exception, e)
        raise
      end

      def next_run_id
        return subagent_run_id if binding.subagent?

        @session.pending_run_id || start_message_run
      end

      def subagent_run_id
        record = current_spawn_record
        return record.run_id unless terminal?(record.run_id)
        return if @session.pending_run_id

        start_subagent_message_run
      end

      def start_message_run
        return unless @session.status == :completed
        return if @session.pending_messages.empty?

        Execution::Start.new(options:, session: @session).prepare(prompt: nil)
      end

      def start_subagent_message_run
        return unless @session.status == :completed && @session.pending_messages.any?

        binding.verifier.verify_record!
        run_id = SecureRandom.uuid_v7
        @session.transaction { Control.new(session: @session).continue_queued(run_id:) }
        # continue_queued carried the grant onto the new run; reload it so verification and
        # materialization use the record keyed to this run.
        @spawn_record = Subagents::Record.latest(@session.entries)
        run_id
      end

      def resume_root
        runtime_options = if options.subagents?
                            Subagents.install(
                              options,
                              host: binding.subagent_host,
                              models: @session.config.model_catalog.keys,
                              resolver: @session.config.tools,
                            )
                          else
                            options
                          end
        Runner.resume(
          config: @session.config,
          options: runtime_options,
          session: @session,
          app: binding.context,
          emit: @events,
          authorize: binding.authorize,
          on_interrupted_tool: binding.on_interrupted_tool,
          run_id: @run_id,
        )
      end

      def resume_subagent
        turn = Subagents::Turn.new(
          session: @session,
          record: current_spawn_record,
          verifier: binding.verifier,
          materialize: method(:materialize_subagent),
          parent: AimHelm.session(current_spawn_record.parent_session_id, store: @session.store),
          app: binding.context,
          emit: @events,
        )
        outcome = turn.call(run_id: @run_id)
        @report = turn.report
        outcome
      rescue ConfigurationError, KeyError => e
        # A grant that will not materialize is poison, not a fault: DispatchGrantError is
        # discarded by the advance job rather than retried.
        raise DispatchGrantError, e.message
      end

      # Re-checked against the reloaded grant: an inline child holds its parent's worker, so it
      # cannot park on a human decision.
      def materialize_subagent(record)
        agent = materialize(record)
        return agent unless current_spawn_record.mode == :inline

        gated = agent.tools.select(&:approval_gated?)
        return agent if gated.empty?

        names = gated.map { it.identifier || it.name }
        raise DispatchGrantError, "subagent grant contains gated tools: #{names.join(", ")}"
      end

      def materialize(record)
        resolver = @session.config.tools || raise(
          ConfigurationError,
          "no durable tool resolver is configured",
        )
        tools = record.tools.map { resolver.resolve(it) }
        agent = record.materialize(tools:)
        return agent unless agent.subagents?

        Subagents.install(agent, host: binding.subagent_host,
                                 models: @session.config.model_catalog.keys,
                                 resolver: @session.config.tools)
      end

      def current_spawn_record = @spawn_record || binding.subagent_record

      def terminal?(run_id)
        @session.entries.any? do
          it.kind == "terminal" && it.run_id == run_id
        end
      end

      def leased_events
        subscribers = Events::Subscribers.new(
          session: @session,
          context: binding.context,
          foreground:,
          broadcast: @session.config.broadcast,
        )
        publisher = Events::Publisher.new(sink: subscribers.active? ? subscribers : nil)
        Events::LeasedSink.new(session: @session, lease: binding.lease, sink: publisher)
      end

      # Release even when closing the sink raises, and wake after release so the next claimer can
      # bind.
      def finish
        @events&.close
      ensure
        binding.lease.release
        wake_for_pending_messages
      end

      def wake_for_pending_messages
        return unless @session.status == :completed
        return if @session.pending_messages.empty?

        @session.config.advance&.call(@session.id)
      end

      def fail_run(reason, error)
        return unless @run_id

        event = Control.new(session: @session).fail_run(run_id: @run_id, reason:, error:)
        @events.call(event) if event
      end
    end
  end
end
