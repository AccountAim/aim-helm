# frozen_string_literal: true

module AimHelm
  module Providers
    class Anthropic
      # Folds Anthropic SSE records into one assistant Message. Content arrives as
      # start/delta/stop triples, so a Builder accumulates the open block while deltas are
      # emitted live; #finish raises unless the stream closed on message_stop with no open block.
      class Assembler < Dry::Struct
        # Scratch for the block currently streaming. `json`, `signature`, and `text` are appended
        # to in place, and `#new` copies those buffers by reference, so a rebuilt Builder keeps
        # what has already streamed.
        class Builder < Dry::Struct
          attribute :id, Types::String.optional.default(nil)
          attribute :index, Types::Integer
          attribute :json, Types::String
          attribute :kind, Types::Symbol
          attribute :name, Types::String.optional.default(nil)
          attribute :redacted, Types::Bool
          attribute :signature, Types::String.optional.default(nil)
          attribute :text, Types::String
        end

        KINDS = {
          "text" => :text,
          "thinking" => :thinking,
          "redacted_thinking" => :thinking,
          "tool_use" => :tool_call,
        }.freeze

        STOP_REASONS = {
          "end_turn" => :stop,
          "max_tokens" => :length,
          "model_context_window_exceeded" => :length,
          "pause_turn" => :tool_use,
          "refusal" => :stop,
          "stop_sequence" => :stop,
          "tool_use" => :tool_use,
        }.freeze

        attribute :model, Types::String

        def feed(record, &)
          case record.fetch("type")
          when "message_start" then start_message(record)
          when "content_block_start" then start_block(record, &)
          when "content_block_delta" then append_delta(record, &)
          when "content_block_stop" then finish_block(&)
          when "message_delta" then update_message(record)
          when "message_stop" then @done = true
          when "error" then raise wire_error(record.fetch("error"))
          end
        end

        def finish(&emit)
          raise ProtocolError, "Anthropic stream ended before message_stop" unless @done
          raise ProtocolError, "Anthropic stream ended with an open content block" if @current

          message = Message.assistant(content: blocks, model:, provider: :anthropic,
                                      usage: current_usage, stop_reason: @stop_reason || :stop)
          emit&.call(type: :"usage.reported", usage: current_usage)
          emit&.call(type: :"turn.completed", message:)
          message
        end

        private

        def start_message(record)
          @current_usage = build_usage(record.dig("message", "usage"))
        end

        def start_block(record, &emit)
          block = record.fetch("content_block")
          kind = KINDS[block.fetch("type")]
          return unless kind

          @current = Builder.new(
            kind:,
            index: blocks.length,
            text: +"",
            json: +"",
            signature: block["data"],
            id: block["id"],
            name: block["name"],
            redacted: block["type"] == "redacted_thinking",
          )
          return unless kind == :tool_call

          emit&.call(type: :"tool.discovered", index: @current.index,
                     call_id: @current.id, name: @current.name)
        end

        def append_delta(record, &)
          delta = record.fetch("delta")

          case delta.fetch("type")
          when "text_delta"
            append_text(delta.fetch("text"), :"message.delta", &)
          when "thinking_delta"
            append_text(delta.fetch("thinking"), :"thinking.delta", &)
          when "signature_delta" then append_signature(delta)
          when "input_json_delta" then append_json(delta, &)
          end
        end

        def append_text(fragment, event, &emit)
          @current.text << fragment
          emit&.call(**delta_event(type: event, index: @current.index, delta: fragment))
        end

        def append_signature(delta)
          @current = @current.new(signature: +"") unless @current.signature
          @current.signature << delta.fetch("signature")
        end

        def append_json(delta, &emit)
          fragment = delta.fetch("partial_json")
          @current.json << fragment
          emit&.call(
            **delta_event(
              type: :"tool.delta",
              index: @current.index,
              call_id: @current.id,
              name: @current.name,
              delta: fragment,
              arguments: partial_tool_call.fetch("arguments"),
            ),
          )
        end

        def delta_event(type:, **fields)
          @sequence = @sequence.to_i + 1
          { type:, sequence: @sequence, **fields }
        end

        def partial_tool_call
          {
            "type" => "tool_call",
            "id" => @current.id,
            "name" => @current.name,
            "arguments" => Streaming::PartialJSON.parse(@current.json),
          }
        end

        def finish_block(&emit)
          return unless @current

          block = case @current.kind
                  when :text
                    { "type" => "text", "text" => @current.text }
                  when :thinking
                    {
                      "type" => "thinking",
                      "thinking" => @current.text,
                      "signature" => @current.signature,
                      "redacted" => @current.redacted,
                    }.compact
                  when :tool_call
                    {
                      "type" => "tool_call",
                      "id" => @current.id,
                      "name" => @current.name,
                      "arguments" => @current.json.empty? ? {} : JSON.parse(@current.json),
                    }
                  end
          blocks << block

          if @current.kind == :tool_call
            emit&.call(type: :"tool.requested", index: @current.index,
                       call_id: block["id"], name: block["name"],
                       arguments: block["arguments"])
          end

          @current = nil
        rescue JSON::ParserError => e
          raise ProtocolError, "invalid Anthropic tool arguments: #{e.message}"
        end

        # message_start carries the input counts and each message_delta a running output total,
        # so the output figure replaces rather than accumulates.
        def update_message(record)
          @stop_reason = stop_reason(record.dig("delta", "stop_reason"))
          output = record.dig("usage", "output_tokens")
          @current_usage = current_usage.new(output_tokens: output.to_i) if output
        end

        def build_usage(raw)
          return Usage.new unless raw

          Usage.new(
            input_tokens: raw.fetch("input_tokens", 0).to_i,
            output_tokens: raw.fetch("output_tokens", 0).to_i,
            cached_input_tokens: raw.fetch("cache_read_input_tokens", 0).to_i,
            cache_write_tokens: raw.fetch("cache_creation_input_tokens", 0).to_i,
          )
        end

        def blocks = @blocks ||= []
        def current_usage = @current_usage ||= Usage.new
        def stop_reason(reason) = STOP_REASONS.fetch(reason, :stop)

        def wire_error(error)
          type = error.fetch("type", "api_error")
          message = error.fetch("message", "Anthropic provider error")
          klass = {
            "authentication_error" => AuthenticationError,
            "rate_limit_error" => RateLimitError,
            "overloaded_error" => OverloadedError,
            "api_error" => ServerError,
          }.fetch(type, ProviderError)
          klass.new(message)
        end
      end
    end
  end
end
