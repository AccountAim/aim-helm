# frozen_string_literal: true

module AimHelm
  class Runner
    # In-memory view of the session transcript for one run: entries indexed by id and topped up
    # with `after_id`, so appends made by tools or another writer join without a full reload.
    # `remember` overwrites by id, keeping the newest copy of an entry.
    module Transcript
      private

      def reload_messages = @messages = Replay.messages(transcript)

      def load_entries
        entries = session.entries
        @entries = entries.to_h { [it.id, it] }
        @loaded_through_id = entries.last&.id || 0
        @wall_clock_checkpoint = monotonic_time
      end

      def refresh_entries
        entries = session.entries(after_id: @loaded_through_id)
        entries.each { remember(it) }
        @loaded_through_id = entries.last.id if entries.any?
      end

      def transcript = @entries.values.sort_by(&:id)
      def remember(entry) = @entries[entry.id] = entry

      def fold_messages
        entry = session.fold_messages(run_id:, entries: transcript)
        remember(entry) if entry
      end

      def stop_requested? = session.stop_requested?(run_id:, entries: transcript)

      def completed_assistant
        message = @messages.last
        return unless message&.role == :assistant
        return if message.tool_calls.any?

        failure = budget_failure
        return failure if failure
        return Success(message) if message.stop_reason == :stop

        Failure([message.stop_reason, message.text])
      end
    end
  end
end
