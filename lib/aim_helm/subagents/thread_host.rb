# frozen_string_literal: true

module AimHelm
  module Subagents
    # In-process subagent host: one thread per session plus an owner thread that serializes the
    # worker registry. Spawns run inline, blocking for the child's report, or in the background
    # for a receipt; the control tools read, steer, stop, and continue children. Execution builds
    # one per run when no durable config.subagent_host is set.
    class ThreadHost < Dry::Struct
      MAX_SUBAGENTS = 5
      POLL_INTERVAL = 0.05
      WAIT_ACTIVITY_INTERVAL = 30
      CLOSE = Object.new.freeze

      attribute :events, Types.Interface(:call).optional.default(nil)
      attribute :max_subagents, Types::Coercible::Integer.constrained(gt: 0).default(MAX_SUBAGENTS)
      attribute :options, Types.Instance(AimHelm::Agent)
      attribute :poll_interval, Types::Coercible::Float.constrained(gt: 0).default(POLL_INTERVAL)

      def initialize(...)
        super
        @commands = Queue.new
        @owner = Thread.new { coordinate({}) }
      end

      def owning(session:, app: nil)
        remember(session:, options:, app:, blocked: true)
        yield
      ensure
        release(session.id)
      end

      def spawn(record:, context:)
        parent = bind(context.session)
        remember(session: parent, options:, app: context.app)
        enforce_capacity!(parent.id)
        subagent = create_subagent(parent, record, context:)
        context.events.publish(record.spawned_event)
        subagent_worker = worker(subagent.id)

        return run_inline(subagent, subagent_worker) if record.mode == :inline

        subagent_worker.call
        Receipt.from(record)
      end

      def read(id:, wait:, timeout:, context:)
        subagent, record = subagent_for(id, context:)
        wait_for_terminal(subagent, timeout:, context:) if wait
        Control.new(session: subagent).read.merge(name: record.name)
      end

      def queue_message(id:, message:, context:)
        subagent, = subagent_for(id, context:)
        Control.new(session: subagent).deliver(content: message)

        { id: subagent.id, status: subagent.status, accepted: true }
      end

      def stop(id:, context:)
        subagent, = subagent_for(id, context:)
        run_id = Control.new(session: subagent).stop
        advance(subagent.id) if run_id
        { id: subagent.id, status: subagent.status }
      end

      def continue(id:, task:, context:)
        subagent, record = subagent_for(id, context:)
        record = record.with(
          run_id: SecureRandom.uuid_v7, task:,
          parent_run_id: context.run_id, call_id: context.call_id
        )

        subagent.transaction do
          Control.new(session: subagent).continue_subagent(record:)
          context.session.append!(
            :subagent, record.marker, key: "subagent:#{record.run_id}",
                                      run_id: context.run_id, turn_id: context.turn_id
          )
        end

        return run_inline(subagent, worker(subagent.id)) if record.mode == :inline

        advance(subagent.id)
        Receipt.from(record)
      end

      def remember(session:, options:, app: nil, parent_id: nil, blocked: false)
        request(:remember, session:, options:, app:, parent_id:, blocked:)
      end

      def advance(session_id) = worker(session_id).call
      def release(session_id) = worker(session_id).release
      def worker(session_id) = request(:fetch, id: session_id.to_s)

      def events_for(session:, context:)
        subscribers = Events::Subscribers.new(
          session:,
          context:,
          foreground: events,
          broadcast: session.config.broadcast,
        )
        subscribers if subscribers.active?
      end

      def close
        # Children close first, so reports they queue onto a parent still get a turn.
        workers = request(:all).sort_by { it.parent_id ? 0 : 1 }
        workers.each(&:close)
        request(:close)
        @owner.join
      end

      private

      def coordinate(workers)
        # The owner thread is the only reader and writer of the worker map.
        loop do
          type, payload, response = @commands.pop
          result = case type
                   when :remember
                     workers[payload.fetch(:session).id] ||= Worker.new(host: self, **payload)
                   when :fetch then workers.fetch(payload.fetch(:id))
                   when :all then workers.values
                   when :count then active_subagents(workers, payload.fetch(:id))
                   when :close then nil
                   end
          response << result
          break if type == :close
        rescue StandardError => e
          response << e
        end
      end

      def create_subagent(parent, record, context:)
        subagent = Session.new(store: parent.store, id: record.session_id, config: parent.config)

        parent.transaction do
          create_session_row(parent, record, context:)
          Control.new(session: subagent).start_subagent(record:)
          parent.append!(
            :subagent,
            record.marker,
            key: "subagent:#{record.session_id}",
            run_id: record.parent_run_id,
            turn_id: context.turn_id,
          )
        end

        subagent_options = worker(parent.id).materialize(record.options)
        remember(
          session: subagent,
          options: subagent_options,
          app: context.app,
          parent_id: parent.id,
          blocked: record.mode == :inline,
        )
        subagent
      end

      # A store that keeps a row per session gets one for the child too, so a thread-hosted
      # subagent is still reachable from its parent once the hosting turn is over.
      def create_session_row(parent, record, context:)
        store = parent.store
        return unless store.respond_to?(:create_session)

        store.create_session(
          context: context.app,
          id: record.session_id,
          name: record.name,
          parent: store.record(parent.id),
        )
      end

      def run_inline(subagent, subagent_worker)
        report = subagent_worker.run_now

        unless report
          raise InlineSubagentBusyError,
                "inline subagent #{subagent.id} produced no terminal report"
        end

        report.output
      ensure
        subagent_worker.release
      end

      def subagent_for(id, context:)
        subagent = worker(id).session
        record = Record.latest(subagent.entries)

        unless record.parent_session_id == context.session.id
          raise DispatchGrantError, "subagent belongs to another session"
        end

        [subagent, record]
      end

      def bind(session)
        config = session.config.with(subagent_host: self, advance: method(:advance))
        session.new(config:)
      end

      def enforce_capacity!(parent_id)
        count = request(:count, id: parent_id.to_s)
        return if count < max_subagents

        raise ArgumentError, "already running #{count} subagents; wait for one to finish"
      end

      def active_subagents(workers, parent_id)
        workers.values.count do
          it.parent_id == parent_id &&
            Session::LIVE_STATUSES.include?(it.session.status)
        end
      end

      def wait_for_terminal(subagent, timeout:, context:)
        deadline = monotonic_time + timeout
        activity_at = monotonic_time + WAIT_ACTIVITY_INTERVAL

        while Session::LIVE_STATUSES.include?(subagent.status) && monotonic_time < deadline
          if monotonic_time >= activity_at
            context.events.publish(
              Event.build(type: :"subagent.waiting", subagent_session_id: subagent.id),
            )
            activity_at = monotonic_time + WAIT_ACTIVITY_INTERVAL
          end

          sleep(poll_interval)
        end
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def request(type, **payload)
        response = Queue.new
        @commands << [type, payload, response]
        result = response.pop
        raise result if result.is_a?(Exception)

        result
      end
    end
  end
end
