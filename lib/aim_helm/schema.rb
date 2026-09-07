# frozen_string_literal: true

module AimHelm
  # Dry::Schema::JSON for every declared schema, so a definition validates the string-keyed hashes
  # read back off the durable log and exposes `json_schema` for provider tool specs.
  module Schema
    module_function

    def define(&) = Dry::Schema.JSON(&)
  end
end
