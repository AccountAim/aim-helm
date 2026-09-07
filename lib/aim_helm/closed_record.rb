# frozen_string_literal: true

module AimHelm
  # Round-trips a Dry::Struct through the durable log. `dump` writes compacted JSON; `deserialize`
  # raises TamperedRecordError for any field outside the struct's schema or any CONTRACT failure,
  # so a tampered payload never materializes. Extenders supply CONTRACT and may override
  # `deserialize_attributes` to rebuild nested structs or `validate_payload!` for whole-payload
  # checks.
  module ClosedRecord
    module InstanceMethods
      def dump = Types::JsonObject[to_h.compact]
    end

    def self.extended(base) = base.include(InstanceMethods)

    def deserialize(payload)
      owned = Types::JsonObject[payload]
      validate_payload!(owned)
      unknown = owned.keys.map(&:to_sym) - record_fields

      if unknown.any?
        raise TamperedRecordError, "unknown #{record_label} fields: #{unknown.join(", ")}"
      end

      result = self::CONTRACT.call(owned)
      raise TamperedRecordError, result.errors.to_h.inspect unless result.success?

      new(**deserialize_attributes(result.to_h))
    end

    def record_fields = schema.keys.map(&:name)

    private

    def deserialize_attributes(attributes) = attributes
    def record_label = name.split("::").last.downcase
    def validate_payload!(_payload); end
  end
end
