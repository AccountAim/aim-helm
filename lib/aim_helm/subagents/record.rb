# frozen_string_literal: true

module AimHelm
  module Subagents
    # The agreed terms of one spawn: child session, turn, name, task, mode, and the exact
    # Agent::Record the child may run. Appended as a `spawn_record` entry when the host creates
    # the child, then re-read and `verify!`ed before that turn executes, so a grant that was
    # edited or re-pointed in the log is refused.
    class Record < Dry::Struct
      VERSION = 1
      MAX_BYTES = 256 * 1024

      CONTRACT = Schema.define do
        required(:version).value(:integer, eql?: VERSION)
        required(:session_id).filled(:string)
        required(:parent_session_id).filled(:string)
        required(:run_id).filled(:string)
        required(:parent_run_id).filled(:string)
        required(:call_id).filled(:string)
        required(:name).filled(:string)
        required(:task) { str? | array? }
        required(:mode).filled(:string, included_in?: %w[inline background])
        required(:options).filled(:hash)
      end

      extend ClosedRecord

      attribute :call_id, Types::String
      attribute :mode, Types::Coercible::Symbol.enum(:inline, :background)
      attribute :name, Types::String
      attribute :options, Types.Instance(AimHelm::Agent::Record)
      attribute :parent_session_id, Types::String
      attribute :parent_run_id, Types::String
      attribute :session_id, Types::String
      attribute :task, Types::String | Types::ContentBlocks
      attribute :run_id, Types::String
      attribute :version, Types::Integer.default(VERSION)

      class << self
        def fetch(entries, run_id:)
          entry = entries.find do
            it.kind == "spawn_record" && it.run_id == run_id
          end
          raise DispatchGrantError, "missing spawn record for turn #{run_id}" unless entry

          deserialize(entry.payload)
        end

        def latest(entries)
          entry = entries.reverse_each.find { it.kind == "spawn_record" }
          raise DispatchGrantError, "subagent session has no spawn record" unless entry

          deserialize(entry.payload)
        end

        # Calls a background child still owes a report: the parent parked them when it delegated,
        # so neither the runner nor a status read should treat them as work of its own.
        def delegated_call_ids(entries)
          answered = entries.filter_map do
            it.payload["call_id"] if it.kind == "tool_result"
          end.to_set
          entries.filter_map do
            next unless it.kind == "subagent" && it.payload["mode"].to_s == "background"

            call_id = it.payload["call_id"]
            call_id unless answered.include?(call_id)
          end.to_set
        end

        def session_ids_for(entries:, call_id:)
          entries.filter_map do
            next unless it.kind == "subagent" && it.payload["call_id"] == call_id

            it.payload.fetch("id")
          end
        end

        private

        def deserialize_attributes(attributes)
          attributes[:options] = Agent::Record.deserialize(attributes.fetch(:options))
          attributes
        end

        def record_label = "subagent record"

        def validate_payload!(payload)
          return unless JSON.generate(payload).bytesize > MAX_BYTES

          raise TamperedRecordError, "spawn record exceeds #{MAX_BYTES} bytes"
        end
      end

      def dump
        Types::JsonObject[to_h.merge(options: options.dump)].tap do
          if JSON.generate(it).bytesize > MAX_BYTES
            raise ConfigurationError, "spawn record exceeds #{MAX_BYTES} bytes"
          end
        end
      end

      # Key-sorted, so a log round-trip that reorders JSON keys still compares equal.
      def canonical = JSON.generate(canonicalize(dump))
      def marker = { id: session_id, name:, task:, mode:, call_id: }

      def spawned_event
        Event.build(
          type: :"subagent.spawned",
          name:,
          subagent_run_id: run_id,
          subagent_session_id: session_id,
          task:,
        )
      end

      def verify!(entries:, session_id:, run_id:)
        durable = self.class.fetch(entries, run_id: self.run_id)

        unless durable.canonical == canonical
          raise DispatchGrantError, "queued subagent grant differs from its spawn record"
        end

        unless self.session_id == session_id.to_s && run_id == self.run_id
          raise DispatchGrantError, "subagent grant targets a different session or turn"
        end

        run_record = Agent::Record.fetch(entries, run_id:)

        unless run_record.dump == options.dump
          raise DispatchGrantError, "subagent run options differ from its spawn record"
        end

        run_record
      end

      # Reads attributes one by one; to_h would flatten the nested Agent::Record into a Hash.
      def with(**changes)
        attributes = self.class.record_fields.to_h { [it, public_send(it)] }
        self.class.new(**attributes, **changes)
      end

      private

      def canonicalize(value)
        case value
        when Hash then value.keys.sort.to_h { [it, canonicalize(value.fetch(it))] }
        when Array then value.map { canonicalize(it) }
        else value
        end
      end
    end
  end
end
