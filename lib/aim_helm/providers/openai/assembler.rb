# frozen_string_literal: true

module AimHelm
  module Providers
    class OpenAI
      # Folds OpenAI Responses events into one assistant Message. Output items arrive as
      # added/delta/done triples, so a Builder accumulates the open item while deltas are
      # emitted live; #finish raises unless a terminal response arrived with no item open.
      class Assembler < Dry::Struct
        # Scratch for the item currently streaming. `json` and `text` are appended to in place,
        # and `#new` copies those buffers by reference, so a rebuilt Builder keeps what has
        # already streamed.
        class Builder < Dry::Struct
          attribute :call_id, Types::String.optional.default(nil)
          attribute :index, Types::Integer
          attribute :item_id, Types::String.optional.default(nil)
          attribute :json, Types::String
          attribute :kind, Types::Symbol
          attribute :name, Types::String.optional.default(nil)
          attribute :summary_index, Types::Integer.optional.default(nil)
          attribute :text, Types::String
        end

        KINDS = {
          "message" => :text,
          "reasoning" => :thinking,
          "function_call" => :tool_call,
        }.freeze

        attribute :model, Types::String

        def feed(record, &)
          case record.fetch("type")
          when "response.output_item.added" then start_item(record, &)
          when "response.output_text.delta" then text_delta(record, &)
          when "response.reasoning_summary_text.delta" then thinking_delta(record, &)
          when "response.function_call_arguments.delta" then arguments_delta(record, &)
          when "response.output_item.done" then finish_item(record, &)
          when "response.completed", "response.incomplete", "response.failed"
            finish_response(record)
          when "error" then @error = wire_error(record)
          end
        end

        def finish(&emit)
          raise @error if @error
          raise ProtocolError, "OpenAI stream ended before a terminal response" unless @status
          raise ProtocolError, "OpenAI stream ended with an open output item" if @current
          raise ProviderError, "OpenAI response failed" if @status == "failed"

          if @status == "incomplete" && @incomplete_reason != "max_output_tokens"
            raise ProviderError, "OpenAI response was incomplete: #{@incomplete_reason}"
          end

          message = Message.assistant(content: blocks, model:, provider: :openai,
                                      usage: current_usage, stop_reason: stop_reason)
          emit&.call(type: :"usage.reported", usage: current_usage)
          emit&.call(type: :"turn.completed", message:)
          message
        end

        private

        def start_item(record, &emit)
          item = record.fetch("item")
          kind = KINDS[item.fetch("type")]
          return unless kind

          @current = Builder.new(
            kind:,
            index: blocks.length,
            text: +"",
            json: +"",
            item_id: item["id"],
            call_id: item["call_id"],
            name: item["name"],
          )
          return unless kind == :tool_call

          emit&.call(type: :"tool.discovered", index: @current.index,
                     call_id: @current.call_id, name: @current.name)
        end

        def text_delta(record, &emit)
          fragment = record.fetch("delta")
          @current.text << fragment
          emit&.call(**delta_event(type: :"message.delta", index: @current.index,
                                   delta: fragment))
        end

        def thinking_delta(record, &emit)
          fragment = record.fetch("delta")
          summary_index = record["summary_index"]

          # Reasoning summaries arrive as numbered parts; a new index opens a paragraph, matching
          # the "\n\n" join used when the item closes.
          if @current.summary_index && summary_index != @current.summary_index
            @current.text << "\n\n"
            emit&.call(**delta_event(type: :"thinking.delta", index: @current.index,
                                     delta: "\n\n"))
          end

          @current = @current.new(summary_index:)
          @current.text << fragment
          emit&.call(**delta_event(type: :"thinking.delta", index: @current.index,
                                   delta: fragment))
        end

        def arguments_delta(record, &emit)
          fragment = record.fetch("delta")
          @current.json << fragment
          emit&.call(
            **delta_event(
              type: :"tool.delta",
              index: @current.index,
              call_id: @current.call_id,
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
            "id" => @current.call_id,
            "name" => @current.name,
            "arguments" => Streaming::PartialJSON.parse(@current.json),
          }
        end

        def finish_item(record, &emit)
          item = record.fetch("item")
          kind = KINDS[item.fetch("type")]
          return unless kind

          refusal = Array(item["content"]).find {  it["type"] == "refusal" }
          raise ProviderError, "OpenAI refused the request: #{refusal["refusal"]}" if refusal

          # Blocks keep the raw wire `item` so a same-model replay can send it back verbatim.
          block = case kind
                  when :text
                    {
                      "type" => "text",
                      "text" => Array(item["content"]).filter_map { it["text"] }.join,
                      "item_id" => item["id"],
                      "item" => item,
                    }
                  when :thinking
                    {
                      "type" => "thinking",
                      "thinking" => Array(item["summary"]).filter_map do
                        it["text"]
                      end.join("\n\n"),
                      "item" => item,
                    }
                  when :tool_call
                    {
                      "type" => "tool_call",
                      "id" => item.fetch("call_id"),
                      "name" => item.fetch("name"),
                      "arguments" => JSON.parse(item.fetch("arguments")),
                      "item_id" => item["id"],
                      "item" => item,
                    }
                  end
          index = @current.index
          blocks << block
          @current = nil

          if kind == :tool_call
            emit&.call(type: :"tool.requested", index:, call_id: block["id"],
                       name: block["name"], arguments: block["arguments"])
          end
        rescue JSON::ParserError => e
          raise ProtocolError, "invalid OpenAI tool arguments: #{e.message}"
        end

        def finish_response(record)
          response = record.fetch("response")
          @status = response.fetch("status")
          @incomplete_reason = response.dig("incomplete_details", "reason")
          @error = response_error(response["error"]) if @status == "failed"
          @current_usage = build_usage(response["usage"]) if response["usage"]
        end

        # OpenAI counts cached tokens inside input_tokens; Usage keeps the two disjoint.
        def build_usage(raw)
          cached = raw.dig("input_tokens_details", "cached_tokens").to_i
          Usage.new(
            input_tokens: [raw.fetch("input_tokens", 0).to_i - cached, 0].max,
            output_tokens: raw.fetch("output_tokens", 0).to_i,
            cached_input_tokens: cached,
            reasoning_tokens: raw.dig("output_tokens_details", "reasoning_tokens").to_i,
          )
        end

        def blocks = @blocks ||= []
        def current_usage = @current_usage ||= Usage.new

        def stop_reason
          return :length if @incomplete_reason == "max_output_tokens"
          return :tool_use if blocks.any? { it["type"] == "tool_call" }

          :stop
        end

        def wire_error(record)
          classify_error(record["code"], record.fetch("message", "OpenAI provider error"))
        end

        def response_error(error)
          return ProviderError.new("OpenAI response failed") unless error

          classify_error(error["code"], error.fetch("message", "OpenAI response failed"))
        end

        def classify_error(code, message)
          code = code.to_s
          klass = if code.include?("rate_limit")
                    RateLimitError
                  elsif code.include?("server")
                    ServerError
                  else
                    ProviderError
                  end
          klass.new(message)
        end
      end
    end
  end
end
