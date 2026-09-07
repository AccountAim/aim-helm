# frozen_string_literal: true

module AimHelm
  module Subagents
    # What a background spawn or continue hands the model in place of a report: the child's id,
    # name, and status to poll with read_agent.
    class Receipt < Dry::Struct
      attribute :id, Types::String
      attribute :name, Types::String
      attribute :status, Types::Coercible::Symbol.enum(:queued, :running)

      def self.from(record, status: :queued)
        new(id: record.session_id, name: record.name, status:)
      end

      def dump = Types::JsonObject[to_h]
    end
  end
end
