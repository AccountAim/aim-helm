# frozen_string_literal: true

module AimHelm
  module Stores
    # File-backed session store: one JSON Lines file per session under `dir`, ids numbered from
    # the last entry. `transaction` buffers appends in memory and writes them once the block
    # returns, so a raised error leaves the file untouched.
    class JSONL < Dry::Struct
      attribute :dir, Types::String

      def append(session_id, kind, payload, key: nil, run_id: nil, turn_id: nil)
        current = entries(session_id)
        return if key && current.any? { it.key == key }

        entry = Session::Record.new(
          id: current.last&.id.to_i + 1,
          session_id:,
          kind: kind.to_s,
          payload:,
          key:,
          run_id:,
          turn_id:,
          created_at: Time.now.utc,
        )
        @pending ? @pending << entry : write([entry])
        entry
      end

      def entries(session_id, after_id: nil)
        entries = if File.exist?(path(session_id))
                    File.readlines(path(session_id), chomp: true).map do
                      Session::Record.deserialize(JSON.parse(it))
                    end
                  else
                    []
                  end
        entries.concat(Array(@pending).select { it.session_id == session_id })
        return entries unless after_id

        entries.drop_while {  it.id <= after_id }
      end

      def transaction
        @pending = []
        result = yield
        write(@pending)
        result
      ensure
        @pending = nil
      end

      private

      def write(entries)
        FileUtils.mkdir_p(dir)

        entries.group_by(&:session_id).each do |session_id, batch|
          lines = batch.map { JSON.generate(it.dump) }.join("\n")
          File.write(path(session_id), "#{lines}\n", mode: "a")
        end
      end

      def path(session_id)
        filename = session_id.to_s.gsub(/[^a-zA-Z0-9_-]/, "-")
        File.join(dir, "#{filename}.jsonl")
      end
    end
  end
end
