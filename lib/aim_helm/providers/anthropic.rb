# frozen_string_literal: true

module AimHelm
  module Providers
    # Anthropic Messages API client. Supplies the request shape — body, headers, stream path,
    # assembler — that the Streaming mixin turns into #stream and #close.
    class Anthropic < Dry::Struct
      include Streaming

      DEFAULT_BASE_URL = "https://api.anthropic.com/v1"
      STREAM_PATH = "messages"
      VERSION = "2023-06-01"

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
        payload[:system] = Serializer.system(system) if system && !system.empty?
        payload[:tools] = Serializer.tools(tools) if tools.any?
        payload[:thinking] = { type: "adaptive", display: "summarized" } if reasoning
        payload[:cache_control] = Serializer::CACHE_CONTROL
        output_config = output_config(output_schema)
        payload[:output_config] = output_config if output_config.any?
        payload
      end

      def base_body(messages)
        {
          model:,
          max_tokens: catalog.fetch(model).max_output,
          stream: true,
          messages: Serializer.messages(messages, model:),
        }
      end

      def output_config(schema)
        {
          effort: reasoning&.to_s,
          format: schema && { type: "json_schema", schema: },
        }.compact
      end

      def headers
        {
          "x-api-key" => api_key,
          "anthropic-version" => VERSION,
        }
      end
    end
  end
end
