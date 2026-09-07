# frozen_string_literal: true

module AimHelm
  module Providers
    module Streaming
      # Decides whether a failed provider call may be replayed and how long to wait first:
      # transient errors only, while nothing has streamed, up to `attempts`. `delay` honours a
      # rate-limit `retry_after`, otherwise backs off exponentially with jitter capped at
      # `max_delay`.
      class RetryPolicy < Dry::Struct
        attribute :attempts, Types::Coercible::Integer.default(3)
        attribute :base_delay, Types::Coercible::Float.default(1.0)
        attribute :max_delay, Types::Coercible::Float.default(30.0)

        def retry?(error, attempt:, emitted:)
          # A partially streamed response cannot be replayed safely.
          !emitted && attempt <= attempts && error.is_a?(TransientError)
        end

        def delay(error, attempt:)
          return error.retry_after.clamp(0.0, max_delay) if error.is_a?(RateLimitError) &&
                                                            error.retry_after

          (base_delay * (2**(attempt - 1)) * rand(0.5..1.0)).clamp(0.0, max_delay)
        end

        TYPE = Types.Instance(self).default { new }
      end
    end
  end
end
