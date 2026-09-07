# frozen_string_literal: true

module AimHelm
  module Stores
    class ActiveRecord
      # Re-checks a subagent's spawn grant against the database before its turn runs: the
      # child's parent row and context must still match the record it was spawned from.
      class Verifier < Dry::Struct
        attribute :record, Types.Interface(:id)
        attribute :session, Types.Instance(AimHelm::Session)
        attribute :spawn_record, Types.Instance(AimHelm::Subagents::Record)
        attribute :store, Types.Instance(AimHelm::Stores::ActiveRecord)

        def verify!(entries:, session_id:, run_id:)
          verify_envelope!
          spawn_record.verify!(entries:, session_id:, run_id:)
        end

        def verify_record!
          verify!(entries: session.entries, session_id: record.id, run_id: spawn_record.run_id)
        end

        private

        def verify_envelope!
          parent = record.parent_session || raise(
            DispatchGrantError,
            "subagent session has no parent envelope",
          )

          if parent.id.to_s == spawn_record.parent_session_id &&
             parent.aim_helm_context == record.aim_helm_context
            return
          end

          raise DispatchGrantError, "subagent session envelope differs from its spawn record"
        end
      end
    end
  end
end
