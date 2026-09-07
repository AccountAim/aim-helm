# frozen_string_literal: true

module AimHelm
  class Compaction
    # Summarizes a transcript and appends the result: a `compaction` entry keyed by the last entry
    # id it covers, plus a `usage` entry for the summarizing call. Returns [] when the newest
    # recorded usage is still under the policy threshold, or when both keyed appends dedupe
    # against an earlier attempt. The summary's own usage carries `purpose: "compaction"` so it
    # never triggers the next check.
    class Runner < Dry::Struct
      attribute(:config, Types.Instance(AimHelm::Config).default { AimHelm.config })
      attribute :policy, Types.Instance(AimHelm::Compaction)
      attribute :summarizer, Types.Interface(:stream, :close).optional.default(nil)

      def call(entries:, session:, model:, run_id:)
        return [] unless compact?(entries, model:)

        covered = entries.last.id
        started_at = monotonic_time
        client = provider(model)
        message = client.stream(
          system: policy.system_prompt,
          messages: Replay.messages(entries),
        )
        usage = append_usage(message, session:, run_id:,
                                      wall_clock: monotonic_time - started_at, covered:)
        compaction = session.append(
          :compaction,
          { summary: message.text, covers_through_entry_id: covered },
          key: "compaction:#{covered}",
          run_id:,
        )
        [usage, compaction].compact
      ensure
        client&.close
      end

      private

      def compact?(entries, model:)
        compaction = entries.reverse_each.find { it.kind == "compaction" }
        usage = entries.reverse_each.find { provider_usage?(it) }
        return false unless usage
        return false if compaction && usage.id < compaction.id

        tokens(usage) >= config.model_catalog.fetch(model).context * policy.threshold
      end

      def tokens(entry)
        Budget::Spend.from([entry]).tokens
      end

      def provider_usage?(entry)
        return true if entry.kind == "assistant" && entry.payload.key?("usage")

        entry.kind == "usage" && entry.payload["purpose"] != "compaction"
      end

      def append_usage(message, session:, run_id:, wall_clock:, covered:)
        usage = message.usage || Usage.new
        session.append(
          :usage,
          usage.to_h.merge(
            model: message.model,
            cost: config.model_catalog.fetch(message.model).cost(usage),
            wall_clock:,
            purpose: :compaction,
          ),
          key: "usage:compaction:#{covered}",
          run_id:,
        )
      end

      def provider(model)
        selected = compactor_model(model)
        catalog = config.model_catalog.fetch(selected)
        reasoning = :low if catalog.reasoning_effort
        summarizer || Providers.resolve(selected, config:, reasoning:)
      end

      def compactor_model(model) = policy.model_for(model)
      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
