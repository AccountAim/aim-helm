# frozen_string_literal: true

module AimHelm
  module Tools
    # One provider tool call after lookup and schema coercion: the raw `source` call, the tool it
    # resolved to, and the coerced `arguments` its handler will receive.
    class PreparedCall < Dry::Struct
      attribute :arguments, Types::JsonObject
      attribute :source, Types::JsonObject
      attribute :tool, Types.Instance(AimHelm::Tool)

      def call_id = source.fetch("id")
      def name = source.fetch("name")
      def approval_required?(context:) = tool.approval_required?(arguments, context:)

      def approval(run_id:, turn_id:)
        Session::Approval.new(
          call_id:,
          name:,
          tool_name: tool.identifier || tool.name,
          arguments:,
          title: tool.name,
          run_id:,
          turn_id:,
        )
      end
    end
  end
end
