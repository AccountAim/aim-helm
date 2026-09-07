# frozen_string_literal: true

module AimHelm
  class Agent
    # Durable snapshot of an Agent definition, appended to the log as a `run_record` entry so a
    # later process can rebuild it. Tools collapse to identifier strings and the output schema to
    # raw JSON Schema, since neither a handler nor a Dry::Schema survives serialization;
    # `materialize(tools:)` rebuilds an Agent once the caller re-resolves those identifiers.
    class Record < Dry::Struct
      VERSION = 1

      CONTRACT = Schema.define do
        required(:version).value(:integer, eql?: VERSION)
        required(:system).value(:string)
        required(:model).filled(:string)
        optional(:reasoning).maybe(:string)
        required(:tools).array(:string)
        optional(:subagents).maybe(:array)
        optional(:output_schema).maybe(:hash)
        optional(:output_retries).maybe(:integer)
        required(:max_iterations).value(:integer)
        optional(:budget).maybe(:hash)
        optional(:compaction).maybe(:hash)
        optional(:reminders).array(:hash)
      end

      extend ClosedRecord

      attribute :budget, Types.Instance(AimHelm::Budget).optional.default(nil)
      attribute :compaction, Agent::COMPACTION
      attribute :max_iterations, Types::Coercible::Integer.default(20)
      attribute :model, Types::String
      attribute :output_retries, Types::Coercible::Integer.constrained(gteq: 0).default(1)
      attribute :output_schema, Types::JsonObject.optional.default(nil)
      attribute :reasoning, Types::Coercible::Symbol.optional.default(nil)
      attribute :reminders,
                Types::Array.of(Types.Instance(AimHelm::Reminder)).default([].freeze)
      attribute :subagents, Types::Array.of(Types.Instance(Subagent)).optional.default(nil)
      attribute :system, Types::String
      attribute :tools, Types::Array.of(Types::String).default([].freeze)
      attribute :version, Types::Integer.default(VERSION)

      class << self
        # Wire names differ from Agent's: instructions -> system, max_turns -> max_iterations.
        def capture(options:, tools: options.tools)
          new(
            system: options.instructions,
            model: options.model,
            reasoning: options.reasoning,
            tools: tool_identifiers(tools),
            subagents: options.subagents,
            output_schema: options.output&.json_schema,
            output_retries: options.output_retries,
            max_iterations: options.max_turns,
            budget: options.budget,
            compaction: options.compaction,
            reminders: options.reminders,
          )
        end

        def fetch(entries, run_id:)
          entry = entries.find do
            it.kind == "run_record" && it.run_id == run_id
          end
          raise TamperedRecordError, "missing run record for turn #{run_id}" unless entry

          deserialize(entry.payload)
        end

        def latest(entries)
          entry = entries.reverse_each.find { it.kind == "run_record" }
          raise TamperedRecordError, "session has no run record" unless entry

          deserialize(entry.payload)
        end

        private

        def tool_identifiers(tools)
          tools.map do
            next it.to_s unless it.is_a?(AimHelm::Tool)

            it.identifier || it.name
          end
        end

        def deserialize_attributes(attributes)
          attributes[:subagents] = attributes[:subagents]&.map do
            Subagent.deserialize(it)
          end
          attributes[:budget] = Budget.deserialize(attributes[:budget]) if attributes[:budget]

          if attributes[:compaction]
            attributes[:compaction] = Compaction.deserialize(attributes[:compaction])
          end

          attributes[:reminders] = Array(attributes[:reminders]).map do
            Reminder.deserialize(it)
          end
          attributes
        end

        def record_label = "agent record"
      end

      def materialize(tools:)
        Agent.new(
          instructions: system,
          model:,
          reasoning:,
          tools:,
          subagents:,
          output: serialized_output_schema,
          output_retries:,
          max_turns: max_iterations,
          budget:,
          compaction:,
          reminders:,
        )
      end

      def dump
        Types::JsonObject[
          to_h.merge(
            subagents: subagents&.map(&:dump),
            budget: budget&.dump,
            compaction: compaction.dump,
            reminders: reminders.map(&:dump),
          ),
        ]
      end

      private

      def serialized_output_schema
        Schema::Serialized.new(json_schema: output_schema) if output_schema
      end
    end
  end
end
