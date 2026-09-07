# frozen_string_literal: true

module AimHelm
  # Recovers work a crashed process left behind: re-dispatches every stale session through
  # `config.advance` and re-delivers background subagent reports to their parents. Raises unless
  # the store answers `stale_session_ids` and `terminal_subagent_ids`. Entered via AimHelm.sweep.
  class Sweep < Dry::Struct
    attribute :store, Types::Store

    def call
      unless store.respond_to?(:stale_session_ids) && store.respond_to?(:terminal_subagent_ids)
        raise ConfigurationError, "configured store does not support sweeping"
      end

      store.stale_session_ids.each { dispatch(it) }
      store.terminal_subagent_ids.each { recover_report(it) }
    end

    private

    def dispatch(id) = AimHelm.config.advance&.call(id.to_s)

    def recover_report(id)
      session = AimHelm.session(id, store:)
      record = Subagents::Record.latest(session.entries)
      parent = AimHelm.session(record.parent_session_id, store:)
      Subagents::ReportRecovery.new(session:, parent:).call
    end
  end
end
