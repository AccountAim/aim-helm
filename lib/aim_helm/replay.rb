# frozen_string_literal: true

module AimHelm
  # Rebuilds the provider-facing message list from durable log entries. Everything a `compaction`
  # entry covers collapses into its summary, each assistant tool call is paired with its recorded
  # `tool_result`, and adjacent user messages merge into one. A call with no recorded result
  # replays as an errored, interrupted result rather than disappearing.
  class Replay
    INTERRUPTED_TOOL_RESULT = "interrupted — may or may not have completed"

    class << self
      def messages(entries)
        summary, transcript = compacted(entries)
        results = tool_results(transcript)
        messages = [summary, *transcript.flat_map do
          replay_entry(it, results)
        end].compact
        merge_users(messages)
      end

      def merge_users(messages)
        messages.each_with_object([]) do |message, replay|
          previous = replay.last

          if previous&.role == :user && message.role == :user
            replay[-1] = Message.user(previous.content + message.content)
          else
            replay << message
          end
        end
      end

      private

      def compacted(entries)
        entry = entries.reverse_each.find { it.kind == "compaction" }
        return [nil, entries] unless entry

        covered = entry.payload.fetch("covers_through_entry_id")
        summary = Message.user("Earlier conversation summary:\n#{entry.payload.fetch("summary")}")
        [summary, entries.drop_while {  it.id <= covered }]
      end

      def replay_entry(entry, results)
        payload = entry.payload

        case entry.kind
        when "user"
          [Message.new(role: :user, content: payload.fetch("content"))]
        when "assistant"
          message = Message.new(
            role: :assistant,
            content: payload.fetch("content"),
            model: payload.fetch("model"),
            provider: payload.fetch("provider"),
            stop_reason: payload.fetch("stop_reason"),
            usage: replay_usage(payload["usage"]),
          )
          [message, *message.tool_calls.map { replay_tool(it, results) }]
        else
          []
        end
      end

      def tool_results(entries)
        entries.filter_map do
          next unless it.kind == "tool_result"

          payload = it.payload
          [payload.fetch("call_id"), payload]
        end.to_h
      end

      def replay_usage(payload)
        Usage.new(**payload.transform_keys(&:to_sym)) if payload
      end

      def replay_tool(call, results)
        call_id = call.fetch("id")
        payload = results.fetch(call_id) do
          {
            "call_id" => call_id,
            "output" => INTERRUPTED_TOOL_RESULT,
            "error" => true,
          }
        end
        Message.tool(
          content: payload.fetch("output"),
          tool_call_id: payload.fetch("call_id"),
          error: payload.fetch("error"),
        )
      end
    end
  end
end
