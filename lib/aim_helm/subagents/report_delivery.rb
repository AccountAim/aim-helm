# frozen_string_literal: true

module AimHelm
  module Subagents
    # Hands a finished child's report to its parent, once. While the parent's spawn call is still
    # open the report is that call's result and the parent resumes the turn it parked; a continued
    # child, or a parent that never parked, gets a queued message that starts its next run.
    class ReportDelivery < Dry::Struct
      attribute :call_id, Types::String
      attribute :parent, Types.Instance(AimHelm::Session)
      attribute :report, Types.Instance(AimHelm::Subagents::Report)

      def call
        entries = parent.entries
        return if delivered?(entries)

        call_entry = open_call(entries)
        call_entry ? answer(call_entry, entries) : queue
      end

      private

      # The marker follows the result so the parent reads as queued for its worker rather than
      # mid-turn, the way an approval decision does.
      def answer(call_entry, entries)
        parent.append(
          :tool_result,
          { call_id:, output: report.message, error: report.status != :completed },
          key: "result:#{call_id}",
          run_id: call_entry.run_id,
          turn_id: call_entry.turn_id,
        )
        parent.append(:report_delivered, { call_id: }, key: key, run_id: call_entry.run_id)
        # A turn still held by an approval resumes on the decision, not on this report.
        return if Session.status_from(entries) == :awaiting_approval

        parent.config.advance&.call(parent.id)
      end

      def queue
        Control.new(session: parent).deliver(
          content: report.message,
          type: :report,
          key: key,
          subagent_session_id: report.id,
          subagent_name: report.name,
          subagent_status: report.status,
        )
      end

      # Only while the call is still open: a continued child reports against a call its earlier
      # report already answered, so that report is a message rather than a result.
      def open_call(entries)
        call = entries.find { it.kind == "tool_call" && it.payload["id"] == call_id }
        return unless call

        answered = entries.any? do
          it.kind == "tool_result" && it.payload["call_id"] == call_id
        end
        call unless answered
      end

      # Landed and consumed: an answered call keeps its marker, and a queued message counts only
      # once the parent has folded it into a turn.
      def delivered?(entries)
        landed = entries.find { it.key == key }
        landed && !parent.pending_messages(entries:).include?(landed)
      end

      def key = "report:#{report.terminal_entry_id}"
    end
  end
end
