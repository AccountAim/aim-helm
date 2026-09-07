# frozen_string_literal: true

module AimHelm
  class Runner
    # Runner's internal run outcome: the final assistant message, its validated output, and
    # whatever it parked on — an approval, or a delegated child still working. Run.from maps it
    # to the public Run subclass callers receive.
    class Result < Dry::Struct
      STATUS = Types::Coercible::Symbol
               .default(:completed)
               .enum(:completed, :awaiting_approval, :awaiting_subagent)

      attribute :message, Types.Instance(AimHelm::Message).optional.default(nil)
      attribute :output, Types::Any.optional.default(nil)
      attribute :pending, Types::Array.of(Types.Instance(AimHelm::Session::Approval)).default([].freeze)
      attribute :session, Types.Instance(AimHelm::Session)
      attribute :status, STATUS
      attribute :run_id, Types::String

      def text = message.text
      def awaiting_approval? = status == :awaiting_approval
      def awaiting_subagent? = status == :awaiting_subagent
      def spend = Budget::Spend.from(session.entries)
      def subagents = session.config.subagent_host
    end
  end
end
