# frozen_string_literal: true

module AimHelm
  class Error < StandardError; end

  class AppendAnomaly < Error; end
  class ReservedEventError < Error; end
  class TamperedRecordError < Error; end
  # A subagent grant that disagrees with its spawn record. Inherits TamperedRecordError so a job
  # that discards tampered records drops the poisoned dispatch instead of retrying it.
  class DispatchGrantError < TamperedRecordError; end
  class InlineSubagentBusyError < Error; end
  class ConfigurationError < Error; end

  class IncompleteRun < Error
    attr_reader :run

    def initialize(run)
      @run = run
      super("run is #{run.status}")
    end
  end

  class ProviderError < Error
    attr_reader :status, :body

    def initialize(message = "provider request failed", status: nil, body: nil)
      @status = status
      @body = body
      super(message)
    end
  end

  class AuthenticationError < ProviderError; end
  class ProtocolError < ProviderError; end

  class TransientError < ProviderError; end
  class OverloadedError < TransientError; end
  class ServerError < TransientError; end
  class ConnectionError < TransientError; end
  class RequestTimeoutError < TransientError; end
  # Not a provider fault: rides the transient tree so job retry policies re-run the lost turn.
  class LeaseLostError < TransientError; end

  class RateLimitError < TransientError
    attr_reader :retry_after

    def initialize(message = "provider rate limit exceeded", retry_after: nil, **)
      @retry_after = retry_after
      super(message, **)
    end
  end
end
