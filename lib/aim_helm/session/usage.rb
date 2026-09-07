# frozen_string_literal: true

module AimHelm
  class Session
    # Token, cost, and wall-clock accounting for a session and its subagents. A provider call
    # records usage on its assistant entry; compaction records a `usage` entry of its own. Both
    # are steps here, so per-model rows and the total account for every call the run paid for.
    class Usage
      # One provider call. `agent` names the subagent that made it, nil for the session itself,
      # and `purpose` marks calls the runner made on its own behalf, like compaction.
      class Step < Dry::Struct
        transform_keys(&:to_sym)

        attribute :cached, Types::Coercible::Integer
        attribute :cost, Types::Coercible::Float
        attribute :input, Types::Coercible::Integer
        attribute :model, Types::String
        attribute :output, Types::Coercible::Integer
        attribute :reasoning, Types::Coercible::Integer
        attribute :sequence, Types::Coercible::Integer
        attribute :wall_clock, Types::Coercible::Float
        attribute? :agent, Types::String.optional
        attribute? :purpose, Types::String.optional

        # Assistant entries carry usage under "usage"; compaction writes the shape as its payload.
        def self.from(entry)
          usage = entry.kind == "usage" ? entry.payload : entry.payload["usage"]
          return unless usage&.dig("model")

          cached = usage.values_at("cached_input_tokens", "cache_write_tokens").sum(&:to_i)

          new(usage.slice("model", "purpose", "cost", "wall_clock").merge(
                "sequence" => entry.id, "cached" => cached,
                "input" => usage["input_tokens"],
                "output" => usage["output_tokens"],
                "reasoning" => usage["reasoning_tokens"]
              ))
        end

        # The transcript row for a step, so a reload replays what the live stream built.
        def self.history_item(entry)
          from(entry)&.to_h&.merge(type: "usage", turn_id: entry.turn_id)
        end

        # The same row for a turn still in flight: the runner prices and persists usage after the
        # provider reports it, so a live event has to be priced here to match.
        def self.live_item(message, catalog:)
          usage = message.usage
          return unless usage

          new(sequence: 0, wall_clock: 0, model: message.model,
              cost: catalog.fetch(message.model).cost(usage),
              input: usage.input_tokens, output: usage.output_tokens,
              reasoning: usage.reasoning_tokens,
              cached: usage.cached_input_tokens + usage.cache_write_tokens).to_h
        end
      end

      # Steps summed over one model, or over the whole run when `model` is nil.
      class Rollup < Dry::Struct
        transform_keys(&:to_sym)

        attribute :calls, Types::Coercible::Integer
        attribute :cached, Types::Coercible::Integer
        attribute :cost, Types::Coercible::Float
        attribute :input, Types::Coercible::Integer
        attribute :output, Types::Coercible::Integer
        attribute :reasoning, Types::Coercible::Integer
        attribute :wall_clock, Types::Coercible::Float
        attribute? :model, Types::String.optional

        def self.of(steps, model: nil)
          new(model:, calls: steps.size, cost: steps.sum(&:cost),
              wall_clock: steps.sum(&:wall_clock),
              **%i[cached input output reasoning].to_h { [it, steps.sum(&it)] })
        end
      end

      def initialize(session)
        @session = session
      end

      # One row per provider call, oldest first, each tagged with the subagent that made it.
      def steps
        @steps ||= ordered_steps.each_with_index.map { |step, index| step.new(sequence: index + 1) }
      end

      def by_model
        steps.group_by(&:model).map { |model, rows| Rollup.of(rows, model:) }
      end

      def total = Rollup.of(steps)
      def last_turn = steps.last

      def to_h
        { steps: steps.map(&:to_h), by_model: by_model.map(&:to_h), total: total.to_h,
          last_turn: last_turn&.to_h }
      end

      protected

      # Durable entry ids order calls across a session and its children; `steps` renumbers them
      # for display only once, at the top of the tree.
      def ordered_steps
        (own_steps + subagent_steps).sort_by(&:sequence)
      end

      private

      attr_reader :session

      def own_steps
        entries.filter_map { Step.from(it) }
      end

      # A spawn appends a `subagent` marker to the parent's log, so the tree walks the durable
      # record rather than any host association.
      def subagent_steps
        entries.select { it.kind == "subagent" }.flat_map do
          marker = it.payload
          child = AimHelm.session(marker.fetch("id"), store: session.store)
          self.class.new(child).ordered_steps.map { it.new(agent: it.agent || marker["name"]) }
        end
      end

      def entries = @entries ||= session.entries
    end
  end
end
