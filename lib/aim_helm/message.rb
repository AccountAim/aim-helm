# frozen_string_literal: true

module AimHelm
  # One provider-neutral turn. `content` holds string-keyed JSON blocks ("text", "tool_call", ...)
  # kept verbatim, so a later request can replay the turn back to the provider that produced it —
  # which is why `model` and `provider` ride along on assistant messages.
  class Message < Dry::Struct
    attribute :content, Types::ContentBlocks.default([].freeze)
    attribute :model, Types::String.optional.default(nil)
    attribute :provider, Types::Provider.optional.default(nil)
    attribute :role, Types::Role
    attribute :stop_reason, Types::Coercible::Symbol.optional.default(nil)
    attribute :tool_call_id, Types::String.optional.default(nil)
    attribute :tool_error, Types::Bool.default(false)
    attribute :usage, Types.Instance(Usage).optional.default(nil)

    class << self
      def system(content) = new(role: :system, content:)
      def user(content) = new(role: :user, content:)

      def assistant(content:, model:, provider:, usage:, stop_reason:)
        new(role: :assistant, content:, model:, provider:, usage:, stop_reason:)
      end

      def tool(content:, tool_call_id:, error: false)
        new(role: :tool, content:, tool_call_id:, tool_error: error)
      end
    end

    def system? = role == :system
    def tool? = role == :tool

    def text
      content.filter_map { it["text"] if it["type"] == "text" }.join
    end

    def tool_calls = content.select { it["type"] == "tool_call" }
  end
end
