# frozen_string_literal: true

module AimHelm
  class Execution
    # Selects the durable run that accepts input: the pending run, a continuation folded from
    # queued messages, or a fresh run with an agent snapshot.
    class Start < Dry::Struct
      attribute :options, Types.Instance(AimHelm::Agent)
      attribute :session, Types.Instance(AimHelm::Session)

      def prepare(prompt:)
        return prepare_prompt(prompt:) unless prompt.nil?
        return session.pending_run_id if session.pending_run_id

        if session.status == :completed && session.pending_messages.any?
          record = Agent::Record.capture(options:)
          return session.transaction { Control.new(session:).continue_queued(record:) }
        end

        raise ConfigurationError, "session has no pending run or queued messages"
      end

      private

      def prepare_prompt(prompt:)
        if session.pending_run_id
          raise ConfigurationError, "session has a pending run; use agent.run to queue input"
        end

        record = Agent::Record.capture(options:)

        session.transaction do
          if session.entries.empty?
            Control.new(session:).start(prompt:, record:)
          elsif Session::TERMINAL_STATUSES.include?(session.status)
            Control.new(session:).continue(prompt:, record:)
          else
            raise ConfigurationError, "session is #{session.status}"
          end
        end
      end
    end
  end
end
