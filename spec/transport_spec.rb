# frozen_string_literal: true

RSpec.describe AimHelm::Providers::Streaming::Transport do
  it "does not create a connection when an unused transport closes" do
    expect(Faraday).not_to receive(:new)

    expect(described_class.new(base_url: "https://example.test").close).to be_nil
  end

  it "classifies rate limits and preserves Retry-After" do
    stub_request(:post, "https://example.test/messages").to_return(
      status: 429,
      headers: { "retry-after" => "2.5" },
      body: '{"error":"busy"}',
    )

    expect do
      described_class.new(base_url: "https://example.test").stream_post("/messages", body: {}) { nil }
    end.to raise_error(AimHelm::RateLimitError) { |error| expect(error.retry_after).to eq(2.5) }
  end

  it "passes successful response chunks through the SSE parser" do
    stub_request(:post, "https://example.test/messages").to_return(
      status: 200,
      body: "data: {\"ok\":true}\n\n",
      headers: { "Content-Type" => "text/event-stream" },
    )

    records = []
    transport = described_class.new(base_url: "https://example.test")
    transport.stream_post("/messages", body: {}) { |record| records << record }

    expect(records).to eq([{ "ok" => true }])
  end
end
