# frozen_string_literal: true

module AimHelm
  module Stores
    class ActiveRecord
      # Durable subagent lifecycle: spawns a child session row, runs it inline or hands it to
      # `config.advance`, and serves the read/queue_message/stop/continue tools. Every call
      # re-checks that the child belongs to the calling parent and shares its context.
      class SubagentHost < Dry::Struct
        MAX_SUBAGENTS = 5

        attribute :store, Types.Instance(AimHelm::Stores::ActiveRecord)

        def spawn(record:, context:)
          parent = parent_for(record, context)
          enforce_capacity!(parent)
          child = persist(parent, record, context)
          context.events.publish(record.spawned_event)

          return dispatch_background(child, record, context) if record.mode == :background

          session = aim_helm_session(child.id)
          # Nothing will retry an inline subagent, so a transient failure must fail the turn.
          AimHelm.agent(session:).advance(
            claimed_by: "inline:#{context.call_id}",
            final_attempt: true,
          )
          report = handle(child, record).report

          unless report
            raise InlineSubagentBusyError,
                  "inline subagent #{child.id} produced no terminal report"
          end

          report.output
        end

        def read(id:, wait:, timeout:, context:)
          child = subagent_for(id, context)
          session = aim_helm_session(child.id)

          if wait
            session.wait(timeout:) do
              context.events.publish(
                Event.build(type: :"subagent.waiting", subagent_session_id: id),
              )
            end
          end

          Control.new(session:).read.merge(name: child.name)
        end

        def queue_message(id:, message:, context:)
          child = subagent_for(id, context)
          session = aim_helm_session(child.id)
          AimHelm.agent(session:).run(message)
          { id: child.id.to_s, status: session.status, accepted: true }
        end

        def stop(id:, context:)
          child = subagent_for(id, context)
          session = aim_helm_session(child.id)
          session.stop
          { id: child.id.to_s, status: session.status }
        end

        def continue(id:, task:, context:)
          child = subagent_for(id, context)
          session = aim_helm_session(child.id)
          record = Subagents::Record.latest(session.entries).with(
            run_id: SecureRandom.uuid_v7, task:,
            parent_run_id: context.run_id, call_id: context.call_id
          )

          session.transaction do
            Control.new(session:).continue_subagent(record:)
            context.session.append!(
              :subagent, record.marker, key: "subagent:#{record.run_id}",
                                        run_id: context.run_id, turn_id: context.turn_id
            )
          end

          return dispatch_background(child, record, context) if record.mode == :background

          AimHelm.agent(session:).advance(claimed_by: "inline:#{context.call_id}",
                                          final_attempt: true)
          report = handle(child, record).report

          unless report
            raise InlineSubagentBusyError,
                  "inline subagent #{child.id} produced no terminal report"
          end

          report.output
        end

        private

        def parent_for(spawn_record, context)
          parent = store.record(context.session.id)

          # RecordNotFound, not an authorization error: a mismatched envelope must not confirm
          # that the row exists.
          unless parent.id.to_s == spawn_record.parent_session_id
            raise ::ActiveRecord::RecordNotFound
          end

          raise ::ActiveRecord::RecordNotFound unless parent.aim_helm_context == context.app

          parent
        end

        def subagent_for(id, context)
          child = store.session_model.find_by!(id:, parent_session_id: context.session.id)
          raise ::ActiveRecord::RecordNotFound unless child.aim_helm_context == context.app

          child
        end

        def enforce_capacity!(parent)
          busy = parent.child_sessions.where(status: %w[queued running awaiting_approval]).count
          return if busy < MAX_SUBAGENTS

          raise ArgumentError, "already running #{busy} subagents; wait for one to finish"
        end

        def persist(parent, spawn_record, tool_context)
          store.transaction do
            child = store.create_session(
              id: spawn_record.session_id,
              context: tool_context.app,
              parent:,
              name: spawn_record.name,
            )
            child_session = aim_helm_session(child.id)
            Control.new(session: child_session).start_subagent(record: spawn_record)
            aim_helm_session(parent.id).append!(
              :subagent,
              spawn_record.marker,
              key: "subagent:#{spawn_record.session_id}",
              run_id: spawn_record.parent_run_id,
              turn_id: tool_context.turn_id,
            )
            child
          end
        end

        def dispatch_background(child, spawn_record, context)
          context.session.config.advance&.call(child.id.to_s)
          Subagents::Receipt.from(spawn_record)
        end

        def handle(child, record)
          Subagent::Handle.new(
            id: child.id.to_s,
            name: record.name,
            task: record.task,
            session: aim_helm_session(child.id),
          )
        end

        def aim_helm_session(id) = AimHelm.session(id, store:)
      end
    end
  end
end
