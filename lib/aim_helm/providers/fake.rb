# frozen_string_literal: true

module AimHelm
  module Providers
    # Scripted stand-in for a live provider. Each entry in `turns` is replayed as one streamed
    # assistant message — or raised as an error — chunked to `chunk_size`, and every request is
    # captured in `#requests`.
    class Fake < Dry::Struct
      attribute :chunk_size, Types::Coercible::Integer.constrained(gt: 0).default(12)
      attribute :model, Types::String.default("gpt-6-luna")
      attribute :turns, Types::Array.of(Types::JsonObject).default([].freeze)

      def stream(system: nil, messages: [], tools: [], output_schema: nil, &emit)
        @sequence = 0
        requests << { system:, messages: messages.dup, tools:, output_schema: }
        turn = remaining.shift ||
               raise(ConfigurationError, "fake provider has no scripted turns left")
        raise_scripted_error(turn, emit) if turn["error"]

        blocks = []
        stream_text(:thinking, turn["thinking"], blocks, emit) if turn["thinking"]
        stream_text(:text, turn["text"], blocks, emit) if turn["text"]
        Array(turn["tool_calls"]).each { stream_tool_call(it, blocks, emit) }
        finish(turn, blocks, emit)
      end

      def close; end
      def requests = @requests ||= []

      private

      def stream_text(kind, text, blocks, emit)
        index = blocks.length
        type = kind == :text ? :"message.delta" : :"thinking.delta"

        text.scan(/.{1,#{chunk_size}}/m) do
          emit&.call(Event.build(type:, index:, delta: it, sequence: next_sequence))
        end

        key = kind == :text ? "text" : "thinking"
        blocks << { "type" => kind.to_s, key => text }
      end

      def stream_tool_call(call, blocks, emit)
        index = blocks.length
        id = call["id"] || next_call_id
        name = call.fetch("name")
        arguments = call.fetch("arguments", {})
        emit&.call(Event.build(type: :"tool.discovered", index:, call_id: id, name:))
        json = +""

        JSON.generate(arguments).scan(/.{1,#{chunk_size}}/m) do
          json << it
          emit&.call(
            Event.build(type: :"tool.delta", index:, call_id: id, name:, delta: it,
                        arguments: Streaming::PartialJSON.parse(json),
                        sequence: next_sequence),
          )
        end

        block = tool_call(id:, name:, arguments:)
        blocks << block
        emit&.call(Event.build(type: :"tool.requested", index:, call_id: id, name:, arguments:))
      end

      def finish(turn, blocks, emit)
        usage = Usage.new(**turn.fetch("usage", {}).transform_keys(&:to_sym))
        reason = turn["stop_reason"] || inferred_stop_reason(blocks)
        message = Message.assistant(
          content: blocks,
          model:,
          provider: :fake,
          usage:,
          stop_reason: reason,
        )
        emit&.call(Event.build(type: :"usage.reported", usage:))
        emit&.call(Event.build(type: :"turn.completed", message:))
        message
      end

      def raise_scripted_error(turn, emit)
        error_class = turn["transient"] ? TransientError : ProviderError
        error = error_class.new(turn.fetch("error"))
        emit&.call(Event.build(type: :"provider.failed", error: error.message))
        raise error
      end

      def tool_call(id:, name:, arguments:)
        { "type" => "tool_call", "id" => id, "name" => name, "arguments" => arguments }
      end

      def inferred_stop_reason(blocks)
        blocks.any? {  it["type"] == "tool_call" } ? :tool_use : :stop
      end

      def next_call_id
        @call_sequence = @call_sequence.to_i + 1
        "fake_call_#{@call_sequence}"
      end

      def next_sequence
        @sequence += 1
      end

      def remaining = @remaining ||= turns.dup
    end
  end
end
