# frozen_string_literal: true

module AimHelm
  module Subagents
    # Re-delivers the report of every background turn a child ran, one per `spawn_record` entry,
    # since a continued child accumulates one record per turn. Sweep runs this for children that
    # reached a terminal state with their parent never notified.
    class ReportRecovery < Dry::Struct
      attribute :parent, Types.Instance(AimHelm::Session)
      attribute :session, Types.Instance(AimHelm::Session)

      def call
        entries = session.entries

        entries.each do
          next unless it.kind == "spawn_record"

          record = Record.deserialize(it.payload)
          next unless record.mode == :background

          report = Report.from(entries:, record:)
          ReportDelivery.new(call_id: record.call_id, parent:, report:).call if report
        end
      end
    end
  end
end
