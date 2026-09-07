# frozen_string_literal: true

module AimHelm
  module Tools
    # Holds one provider turn's tool set and approval wiring and hands it to a single Batch;
    # `close` shuts the executor's thread pool down.
    class Runner < Dry::Struct
      attribute(:authorize, Types.Interface(:call).default { Batch::NO_AUTHORIZATION })
      attribute :max_concurrency,
                Types::Coercible::Integer.constrained(gt: 0).default(Executor::MAX_CONCURRENCY)
      attribute(:on_interrupted_tool,
                Types.Interface(:call).default { Batch::NO_INTERRUPTED_TOOL_HANDLER })
      attribute :tools, Types::Array.of(Types.Instance(AimHelm::Tool))

      def start(calls:, entries:, session:, run_id:, turn_id:, events:, app: nil)
        with_batch(session:, run_id:, turn_id:, events:, app:) do
          it.start(calls, entries:)
        end
      end

      def resume(entries:, session:, run_id:, turn_id:, events:, app: nil)
        with_batch(session:, run_id:, turn_id:, events:, app:) do
          it.resume(entries:)
        end
      end

      def close
        @executor&.shutdown
        @executor = nil
      end

      private

      def with_batch(session:, run_id:, turn_id:, events:, app:)
        @executor = executor(session:, run_id:, turn_id:, events:, app:)
        yield Batch.new(
          session:,
          executor: @executor,
          run_id:,
          turn_id:,
          emit: events,
          authorize:,
          on_interrupted_tool:,
          app:,
        )
      ensure
        close
      end

      def executor(session:, run_id:, turn_id:, events:, app:)
        Executor.new(
          tools:,
          session:,
          app:,
          run_id:,
          turn_id:,
          emit: events,
          max_concurrency:,
        )
      end
    end
  end
end
