# frozen_string_literal: true

module AimHelm
  module Subagents
    # A finished child turn reduced to what the parent needs: status, the child's last assistant
    # text, and any error, tagged with the terminal entry that produced it. `from` returns nil
    # while that entry is absent, so callers read nil as "not finished".
    class Report < Dry::Struct
      attribute :error, Types::String.optional.default(nil)
      attribute :id, Types::String
      attribute :name, Types::String
      attribute :status, Types::Coercible::Symbol.enum(:completed, :failed, :stopped)
      attribute :terminal_entry_id, Types::Coercible::String
      attribute :text, Types::String.optional.default(nil)

      class << self
        def from(entries:, record:)
          terminal = entries.find do
            it.kind == "terminal" && it.run_id == record.run_id
          end
          return unless terminal

          payload = terminal.payload
          new(
            id: record.session_id,
            name: record.name,
            status: canonical_status(payload.fetch("outcome")),
            text: response_text(entries, record.run_id),
            error: payload["error"],
            terminal_entry_id: terminal.id,
          )
        end

        private

        def response_text(entries, run_id)
          turn_entries = entries.select { it.run_id == run_id }
          message = Replay.messages(turn_entries).reverse_each.find do
            it.role == :assistant
          end
          message&.text
        end

        def canonical_status(outcome)
          outcome.to_sym == :done ? :completed : outcome
        end
      end

      def output = dump.except("terminal_entry_id")
      def message = "Sub-agent #{name} (#{id}) finished #{status}:\n#{text || error || status}"
      def dump = Types::JsonObject[to_h.compact]
    end
  end
end
