# frozen_string_literal: true

RSpec.describe AimHelm::Providers::Streaming::SSE do
  it "parses partial chunks, comments, and multi-line data" do
    parser = described_class.new
    records = []
    fragments = [
      ": heartbeat\r\nev",
      "ent: response\r\ndata: {\"value\":\r\n",
      "data: 1}\r\n\r\ndata: [DONE]\r\n\r\n",
    ]

    fragments.each { |fragment| parser.feed(fragment) { |record| records << record } }
    parser.finish { |record| records << record }

    expect(records).to eq([{ "value" => 1 }])
  end

  it "rejects non-object data" do
    parser = described_class.new

    expect do
      parser.feed("data: []\n\n") { nil }
    end.to raise_error(AimHelm::ProtocolError, "SSE data must be a JSON object")
  end

  it "parses recorded streams independently of response chunking" do
    expect(sse_records("streams/anthropic_turn.sse").last).to eq("type" => "message_stop")
    expect(sse_records("streams/openai_turn.sse").last).to include("type" => "response.completed")
  end
end
