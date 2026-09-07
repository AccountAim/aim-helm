# frozen_string_literal: true

module AimHelm
  module Stores
    # In-process session store; Agent#run falls back to one when given no session.
    class Memory
      def initialize
        @entries = Hash.new { |sessions, id| sessions[id] = [] }
      end

      def append(session_id, kind, payload, key: nil, run_id: nil, turn_id: nil)
        current = @entries[session_id]
        return if key && current.any? { it.key == key }

        record = Session::Record.new(
          id: current.length + 1,
          session_id:,
          kind: kind.to_s,
          payload:,
          key:,
          run_id:,
          turn_id:,
          created_at: Time.now.utc,
        )
        current << record
        record
      end

      def entries(session_id, after_id: nil)
        records = @entries.fetch(session_id, []).dup
        return records unless after_id

        records.drop_while {  it.id <= after_id }
      end

      def transaction = yield
    end
  end
end
