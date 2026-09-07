# frozen_string_literal: true

module AimHelm
  module Providers
    class Anthropic
      # Builds Anthropic Messages API payloads from AimHelm history. The API takes alternating
      # turns, so consecutive tool results collapse into one user message and adjacent same-role
      # turns merge.
      module Serializer
        CACHE_CONTROL = { type: "ephemeral" }.freeze

        module_function

        def system(content) = [{ type: "text", text: content, cache_control: CACHE_CONTROL }]

        def messages(history, model:)
          groups = history.reject(&:system?).chunk_while do |left, right|
            left.tool? && right.tool?
          end
          serialized = groups.map do
            it.first.tool? ? tool_results(it) : message(it.first, model:)
          end
          merge_turns(serialized)
        end

        def replay(entries, model:) = messages(Replay.messages(entries), model:)

        def tools(definitions)
          definitions.map do
            tool = it.transform_keys(&:to_sym)
            {
              name: tool.fetch(:name),
              description: tool.fetch(:description),
              input_schema: tool.fetch(:input_schema),
            }
          end
        end

        def message(message, model:)
          # Signed thinking blocks are replayable only to their producing provider and model.
          own_model = message.provider == :anthropic && message.model == model
          {
            role: message.role.to_s,
            content: message.content.filter_map { block(it, own_model:) },
          }
        end

        def tool_results(messages)
          {
            role: "user",
            content: messages.map { tool_result(it) },
          }
        end

        def merge_turns(messages)
          messages.each_with_object([]) do |message, turns|
            previous = turns.last

            if previous&.fetch(:role) == message.fetch(:role)
              previous.fetch(:content).concat(message.fetch(:content))
            else
              turns << message
            end
          end
        end

        def block(content, own_model:)
          case content.fetch("type")
          when "text" then text(content)
          when "thinking" then thinking(content, own_model:)
          when "image" then Image.from(content).anthropic
          when "tool_call" then tool_call(content)
          end
        end

        # A redacted block carries its opaque payload in `signature`; the wire field is `data`.
        def thinking(content, own_model:)
          if own_model && content["redacted"]
            { type: "redacted_thinking", data: content.fetch("signature") }
          elsif own_model && content["signature"]
            {
              type: "thinking",
              thinking: content.fetch("thinking"),
              signature: content.fetch("signature"),
            }
          elsif !content.fetch("thinking").empty?
            { type: "text", text: content.fetch("thinking") }
          end
        end

        def tool_result(message)
          content = message.content.filter_map {  block(it, own_model: false) }
          # The API rejects an empty tool_result body, so send a blank text block.
          content = [{ type: "text", text: " " }] if content.empty?
          {
            type: "tool_result",
            tool_use_id: message.tool_call_id,
            content:,
            is_error: message.tool_error,
          }
        end

        def text(content)
          text = content.fetch("text")
          { type: "text", text: } unless text.empty?
        end

        def tool_call(content)
          {
            type: "tool_use",
            id: content.fetch("id"),
            name: content.fetch("name"),
            input: content.fetch("arguments"),
          }
        end
      end
    end
  end
end
