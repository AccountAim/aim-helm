# frozen_string_literal: true

module AimHelm
  module Schema
    # An output schema restored from the log, holding raw JSON Schema because the Dry::Schema
    # block that produced it cannot be serialized. Types::OutputSchema accepts it wherever a
    # Dry::Schema::Processor goes, and Types::JsonSchema reads `json_schema` off either.
    class Serialized < Dry::Struct
      attribute :json_schema, Types::JsonObject
    end
  end
end
