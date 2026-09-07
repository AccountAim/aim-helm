# frozen_string_literal: true

module AimHelm
  class Execution
    # Everything one leased turn needs, assembled by the store when the lease is claimed: the held
    # lease, the application context, the authorization and interrupted-tool callbacks, and — for
    # a child session — the spawn record plus the verifier that must pass before it runs.
    class Binding < Dry::Struct
      attribute(:authorize,
                Types.Interface(:call).default { Tools::Batch::NO_AUTHORIZATION })
      attribute :context, Types.Instance(Object).optional.default(nil)
      attribute :final_attempt, Types::Bool.default(false)
      attribute :lease, Types.Interface(:heartbeat?, :release)
      attribute(:on_interrupted_tool,
                Types.Interface(:call).default { Tools::Batch::NO_INTERRUPTED_TOOL_HANDLER })
      attribute :session, Types.Instance(AimHelm::Session)
      attribute :subagent_host, Config::SUBAGENT_HOST.default(nil)
      attribute :subagent_record, Types.Instance(Subagents::Record).optional.default(nil)
      attribute :verifier, Types.Interface(:verify!).optional.default(nil)

      def subagent? = !subagent_record.nil?
    end
  end
end
