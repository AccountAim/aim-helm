# frozen_string_literal: true

module AimHelm
  class Subagent
    # One child session addressed from the parent: read its status, transcript, or report, send
    # it more input, or stop it. Session#subagents builds one per `subagent` entry in the parent
    # log.
    class Handle < Dry::Struct
      attribute :id, Types::String
      attribute :name, Types::String
      attribute :session, Types.Instance(AimHelm::Session)
      attribute :task, Types::String | Types::ContentBlocks

      def status = session.status
      def transcript = session.transcript

      def report
        record = Subagents::Record.latest(session.entries)
        Subagents::Report.from(entries: session.entries, record:)
      end

      def run(input = nil, **attributes, &)
        AimHelm.agent(session:).run(input, **attributes, &)
      end

      def stop(reason: nil) = session.stop(reason:)
    end
  end
end
