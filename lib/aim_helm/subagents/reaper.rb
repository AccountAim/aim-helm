# frozen_string_literal: true

module AimHelm
  module Subagents
    # Stops every subagent a single tool call spawned, found through the parent's `subagent`
    # entries. Wired as the store's on_interrupted_tool hook, so a call that died mid-flight
    # leaves no orphaned children.
    class Reaper < Dry::Struct
      attribute :parent, Types.Instance(AimHelm::Session)

      def call(tool_call:, entries:)
        ids = Record.session_ids_for(entries:, call_id: tool_call.fetch("id"))

        parent.subagents.each do
          it.stop if ids.include?(it.id)
        end
      end
    end
  end
end
