# frozen_string_literal: true

module AimHelm
  module Providers
    # OpenAI Responses API client. Supplies the request shape — body, headers, stream path,
    # assembler — that the Streaming mixin turns into #stream and #close.
    class OpenAI < Dry::Struct
      include Streaming

      DEFAULT_BASE_URL = "https://api.openai.com/v1"
      STREAM_PATH = "responses"

      attribute :api_key, Types::String
      attribute(:catalog, Types::Hash.default { Catalog.default })
      attribute :model, Types::String
      attribute :open_timeout, Types::Coercible::Float.default(15.0)
      attribute :base_url, Types::String.default(DEFAULT_BASE_URL)
      attribute :read_timeout, Types::Coercible::Float.default(300.0)
      attribute :reasoning, Types::Coercible::Symbol.optional.default(nil)
      attribute :retry_policy, Streaming::RetryPolicy::TYPE
      attribute :write_timeout, Types::Coercible::Float.default(60.0)

      private

      def build_assembler = Assembler.new(model:)
      def stream_path = STREAM_PATH

      def body(system, messages, tools, output_schema)
        payload = base_body(messages)
        payload[:instructions] = system if system && !system.empty?
        payload[:tools] = Serializer.tools(tools) if tools.any?
        payload[:reasoning] = { effort: reasoning.to_s, summary: "auto" } if reasoning
        payload[:text] = output_format(output_schema) if output_schema
        payload
      end

      def base_body(messages)
        {
          model:,
          input: Serializer.input(messages, model:),
          stream: true,
          # store: false keeps history client-side, so reasoning has to come back encrypted to be
          # replayable as a wire item.
          store: false,
          include: ["reasoning.encrypted_content"],
        }
      end

      def output_format(schema)
        { format: { type: "json_schema", name: "output", strict: true, schema: } }
      end

      def headers
        { "Authorization" => "Bearer #{api_key}" }
      end
    end
  end
end
