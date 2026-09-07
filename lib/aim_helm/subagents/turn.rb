# frozen_string_literal: true

module AimHelm
  module Subagents
    # Runs one child turn: verifies the grant against the durable log before anything executes,
    # resumes the Runner with the options verification returned, then folds the result into a
    # Report, delivered to the parent when the child is a background one. `report` keeps the last
    # one built.
    class Turn < Dry::Struct
      attribute :app, Types.Instance(Object).optional.default(nil)
      attribute :emit, Types.Interface(:call).optional.default(nil)
      attribute :materialize, Types.Interface(:call)
      attribute :parent, Types.Instance(AimHelm::Session)
      attribute :record, Types.Instance(Record)
      attribute :session, Types.Instance(AimHelm::Session)
      attribute :verifier, Types.Interface(:verify!)

      attr_reader :report

      def call(run_id:)
        entries = session.entries
        run_record = verifier.verify!(entries:, session_id: session.id, run_id:)
        outcome = Runner.resume(
          config: session.config,
          options: materialize.call(run_record),
          session:,
          app:,
          emit:,
          run_id:,
        )
        @report = Report.from(entries: session.entries, record:)
        deliver(@report)
        outcome
      end

      private

      def deliver(report)
        return unless report && record.mode == :background

        ReportDelivery.new(call_id: record.call_id, parent:, report:).call
      end
    end
  end
end
