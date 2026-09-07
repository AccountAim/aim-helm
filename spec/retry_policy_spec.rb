# frozen_string_literal: true

RSpec.describe AimHelm::Providers::Streaming::RetryPolicy do
  subject(:policy) { described_class.new(attempts: 1, base_delay: 1, max_delay: 5) }

  it "retries transient failures only before an event is emitted" do
    error = AimHelm::OverloadedError.new("busy")

    expect(policy.retry?(error, attempt: 1, emitted: false)).to be(true)
    expect(policy.retry?(error, attempt: 1, emitted: true)).to be(false)
    expect(policy.retry?(error, attempt: 2, emitted: false)).to be(false)
    expect(policy.retry?(AimHelm::ProviderError.new, attempt: 1, emitted: false)).to be(false)
  end

  it "honors Retry-After within the configured delay limit" do
    error = AimHelm::RateLimitError.new(retry_after: 20)

    expect(policy.delay(error, attempt: 1)).to eq(5.0)
  end
end
