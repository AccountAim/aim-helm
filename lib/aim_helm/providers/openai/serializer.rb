# frozen_string_literal: true

module AimHelm
  module Providers
    class OpenAI
      # Builds OpenAI Responses API input from AimHelm history: one flat item list where every
      # assistant block becomes its own item, replayed as the verbatim wire item when it came
      # from this provider and model.
      module Serializer
        module_function

        def input(history, model:)
          history.reject(&:system?).flat_map { items(it, model:) }
        end

        def replay(entries, model:) = input(Replay.messages(entries), model:)

        def tools(definitions)
          definitions.map do
            tool = it.transform_keys(&:to_sym)
            {
              type: "function",
              name: tool.fetch(:name),
              description: tool.fetch(:description),
              parameters: tool.fetch(:input_schema),
            }
          end
        end

        def items(message, model:)
          case message.role
          when :user then [user_item(message)]
          when :tool then [tool_result(message)]
          when :assistant then assistant_items(message, model:)
          else []
          end
        end

        def user_item(message)
          {
            role: "user",
            content: message.content.filter_map { user_content(it) },
          }
        end

        def user_content(content)
          case content.fetch("type")
          when "text"
            { type: "input_text", text: content.fetch("text") }
          when "image" then Image.from(content).openai
          end
        end

        def tool_result(message)
          {
            type: "function_call_output",
            call_id: message.tool_call_id,
            output: tool_output(message),
          }
        end

        # Images need the content-array form of `output`; text-only results stay a plain string.
        def tool_output(message)
          return message.text if message.content.none? { it["type"] == "image" }

          message.content.filter_map { user_content(it) }
        end

        def assistant_items(message, model:)
          # Provider wire items are replayable only to their producing provider and model.
          own_model = message.provider == :openai && message.model == model
          message.content.filter_map { assistant_item(it, own_model:) }
        end

        def assistant_item(content, own_model:)
          case content.fetch("type")
          when "text" then text_item(content, own_model:)
          when "thinking" then reasoning_item(content, own_model:)
          when "tool_call" then function_call_item(content, own_model:)
          end
        end

        def text_item(content, own_model:)
          return content.fetch("item") if own_model && content["item"]

          {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: content.fetch("text") }],
          }
        end

        def reasoning_item(content, own_model:)
          return content.fetch("item") if own_model && content["item"]
          return if content.fetch("thinking").empty?

          {
            type: "message",
            role: "assistant",
            content: [{ type: "output_text", text: content.fetch("thinking") }],
          }
        end

        def function_call_item(content, own_model:)
          return content.fetch("item") if own_model && content["item"]

          {
            type: "function_call",
            call_id: content.fetch("id"),
            name: content.fetch("name"),
            arguments: JSON.generate(content.fetch("arguments")),
          }
        end
      end
    end
  end
end
