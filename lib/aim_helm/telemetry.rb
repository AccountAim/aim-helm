# frozen_string_literal: true

module AimHelm
  # No-op sink and the default for `config.telemetry`; a host replaces it with any callable taking
  # an event name plus keyword fields to observe runtime faults.
  module Telemetry
    module_function

    def call(*) = nil
  end
  Telemetry.freeze
end
