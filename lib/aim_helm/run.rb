# frozen_string_literal: true

module AimHelm
  # The outcome of a run — Queued, Completed, AwaitingApproval, Stopped, or Failed — each
  # carrying the run id and the session it ran in, with predicates so a caller branches without
  # matching on class. Returned from Agent#run and Agent#advance.
  class Run < Dry::Struct
    attribute :id, Types::String
    attribute :session, Types.Instance(AimHelm::Session)

    def status = self.class::STATUS
    def queued? = false
    def completed? = false
    def awaiting_approval? = false
    def awaiting_subagent? = false
    def stopped? = false
    def failed? = false

    class Queued < Run
      STATUS = :queued

      def queued? = true
    end

    class Completed < Run
      STATUS = :completed

      attribute :message, Types.Instance(AimHelm::Message)
      attribute :output, Types::Any.optional.default(nil)

      def text = message.text
      def spend = Budget::Spend.from(session.entries)
      def completed? = true
    end

    class AwaitingApproval < Run
      STATUS = :awaiting_approval

      attribute :pending_approvals,
                Types::Array.of(Types.Instance(AimHelm::Session::Approval)).default([].freeze)

      def awaiting_approval? = true
    end

    # The turn parked on a delegated child: it resumes when the child's report answers the call.
    class AwaitingSubagent < Run
      STATUS = :awaiting_subagent

      def awaiting_subagent? = true
    end

    class Stopped < Run
      STATUS = :stopped

      attribute :detail, Types::Any.optional.default(nil)
      attribute :reason, Types::Coercible::Symbol

      def stopped? = true
    end

    class Failed < Run
      STATUS = :failed

      attribute :detail, Types::Any.optional.default(nil)
      attribute :reason, Types::Coercible::Symbol

      def failed? = true
    end

    class << self
      def from(outcome, session:, id:)
        if outcome.success?
          from_result(outcome.value!)
        else
          from_failure(outcome.failure, session:, id:)
        end
      end

      private

      def from_result(result)
        if result.awaiting_approval?
          AwaitingApproval.new(
            id: result.run_id,
            session: result.session,
            pending_approvals: result.pending,
          )
        elsif result.awaiting_subagent?
          AwaitingSubagent.new(id: result.run_id, session: result.session)
        else
          Completed.new(
            id: result.run_id,
            session: result.session,
            message: result.message,
            output: result.output,
          )
        end
      end

      def from_failure(failure, session:, id:)
        reason, detail = failure
        klass = reason == :cancelled ? Stopped : Failed
        klass.new(id:, session:, reason:, detail:)
      end
    end
  end
end
