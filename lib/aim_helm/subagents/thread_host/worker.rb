# frozen_string_literal: true

module AimHelm
  module Subagents
    class ThreadHost
      # One thread per remembered session, serializing that session's turns: `call` queues one,
      # `run_now` runs one on the calling thread, `close` drains and joins. A `blocked` worker
      # parks on its gate until `release`, so the caller that owns the turn — an inline spawn, or
      # Execution running the root session — runs it without this thread racing ahead.
      class Worker < Dry::Struct
        attribute :app, Types.Instance(Object).optional.default(nil)
        attribute :blocked, Types::Bool.default(false)
        attribute :host, Types.Instance(ThreadHost)
        attribute :options, Types.Instance(AimHelm::Agent)
        attribute :parent_id, Types::String.optional.default(nil)
        attribute :session, Types.Instance(AimHelm::Session)

        def initialize(...)
          super
          @queue = Queue.new
          @gate = Queue.new if blocked
          @thread = Thread.new { run }
        end

        def call = @queue << true
        def release = @gate&.push(true)
        def run_now = work

        def materialize(record)
          pool = options.tools.to_h do
            identifier = it.identifier || it.name
            [identifier, it]
          end
          record.materialize(tools: record.tools.map { pool.fetch(it) })
        end

        def close
          release
          @queue << CLOSE
          @thread.join
        end

        private

        def run
          @gate&.pop

          loop do
            command = @queue.pop
            break if command.equal?(CLOSE)

            work
          end
        end

        def work
          run_id = next_turn
          return unless run_id

          return run_subagent(run_id) if parent_id

          runtime_options = Subagents.install(
            materialize(Agent::Record.fetch(session.entries, run_id:)),
            host:,
            models: session.config.model_catalog.keys,
            resolver: session.config.tools,
          )
          Runner.resume(
            config: session.config,
            options: runtime_options,
            session:,
            app:,
            emit: host.events_for(session:, context: app),
            run_id:,
          )
        end

        def run_subagent(run_id)
          record = Record.latest(session.entries)
          parent = host.worker(record.parent_session_id).session
          turn = Turn.new(
            session:,
            record:,
            verifier: record,
            materialize: method(:materialize),
            parent:,
            app:,
            emit: host.events_for(session:, context: app),
          )
          turn.call(run_id:)
          turn.report
        end

        def next_turn
          run_id = session.pending_run_id
          return run_id if run_id
          return unless session.status == :completed && session.pending_messages.any?

          run_id = SecureRandom.uuid_v7

          session.transaction do
            Control.new(session:).continue_queued(run_id:)
          end

          run_id
        end
      end
    end
  end
end
