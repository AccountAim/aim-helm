# frozen_string_literal: true

module AimHelm
  class Runner
    # Usage, cost, and budget arithmetic for one turn: prices each assistant message from the
    # model catalog, checkpoints wall clock between them, and compacts the transcript when the
    # turn ends. A compaction failure is logged and swallowed so the completed turn still returns.
    module Accounting
      private

      def usage_payload(message)
        usage = message.usage || Usage.new
        usage.to_h.merge(
          model: message.model,
          cost: config.model_catalog.fetch(message.model).cost(usage),
          wall_clock: checkpoint_wall_clock,
        )
      end

      # live_wall_clock is only the span since the last assistant message; earlier spans are
      # already summed from transcript usage.
      def budget_exhaustion
        budget&.exhaustion(
          transcript,
          live_wall_clock: monotonic_time - @wall_clock_checkpoint,
        )
      end

      def budget_failure
        detail = budget_exhaustion
        Failure([:budget_exhausted, JSON.generate(detail)]) if detail
      end

      def checkpoint_wall_clock
        now = monotonic_time
        elapsed = now - @wall_clock_checkpoint
        @wall_clock_checkpoint = now
        elapsed
      end

      def compact
        entries = compaction_runtime.call(
          entries: transcript,
          session:,
          model: model || options.model,
          run_id:,
        )
        entries.each { remember(it) }
      rescue StandardError => e
        config.telemetry.call(
          :compaction_failed,
          count: 1,
          session_id: session.id,
          error_class: e.class.name,
        )
        config.logger.error("AimHelm compaction failed: #{e.message}")
      end

      def compaction_runtime
        @compaction_runtime ||= compactor || Compaction::Runner.new(
          policy: options.compaction,
          config:,
        )
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
