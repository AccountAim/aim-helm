# frozen_string_literal: true

module AimHelm
  # Active Job seam for config.advance: `dispatch` enqueues one advance for a session on the root
  # or subagent queue from config.
  module ActiveJob
    class << self
      def dispatch(session_id, config: AimHelm.config)
        job = config.advance_job || AdvanceSessionJob
        queue = config.store.subagent?(session_id) ? config.subagent_queue : config.root_queue
        job.set(queue:).perform_later(session_id.to_s)
      end
    end

    # Default advance worker: claims the session's next run, retries transient provider failures
    # with backoff, and marks the pending run failed before discarding a run record it cannot
    # trust. Hosts substitute a subclass through config.advance_job.
    class AdvanceSessionJob < ::ActiveJob::Base
      RETRY_ATTEMPTS = 5

      retry_on AimHelm::TransientError,
               wait: :polynomially_longer,
               attempts: RETRY_ATTEMPTS
      discard_on AimHelm::TamperedRecordError, AimHelm::ConfigurationError

      def perform(session_id)
        session = AimHelm.session(session_id)
        advance(session)
      end

      private

      def advance(session)
        AimHelm.agent(session:).advance(
          claimed_by: job_id,
          final_attempt: executions >= RETRY_ATTEMPTS,
        )
      rescue AimHelm::TamperedRecordError, AimHelm::ConfigurationError => e
        fail_invalid_record(session, e)
        raise
      end

      def fail_invalid_record(session, error)
        run_id = session.pending_run_id
        return unless run_id

        event = Control.new(session:).fail_run(
          run_id:,
          reason: :invalid_run_record,
          error:,
        )
        return unless event && session.config.broadcast

        context = session.store.context(session.id) if session.store.respond_to?(:context)
        delivery = Events::Delivery.new(event:, session:, context:)
        session.config.broadcast.call(delivery)
      end
    end
  end
end
