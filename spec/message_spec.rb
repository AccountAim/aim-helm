# frozen_string_literal: true

RSpec.describe AimHelm::Message do
  it "coerces Image elements into image blocks through to_content" do
    image = AimHelm::Image.data("png-bytes", media_type: "image/png")
    message = described_class.tool(content: ["caption", image], tool_call_id: "call_1")

    expect(message.content).to eq(
      [
        { "type" => "text", "text" => "caption" },
        {
          "type" => "image",
          "source" => {
            "type" => "base64",
            "media_type" => "image/png",
            "data" => ["png-bytes"].pack("m0"),
          },
        },
      ],
    )
  end

  it "normalizes scalar content into frozen text blocks" do
    message = described_class.user("hello")

    expect(message.content).to eq([{ "type" => "text", "text" => "hello" }])
    expect(message.content.first).to be_frozen
    expect(message.text).to eq("hello")
  end

  it "exposes tool calls separately from text" do
    message = described_class.assistant(
      content: [
        { type: "text", text: "working" },
        { type: "tool_call", id: "call_1", name: "search", arguments: { query: "ruby" } },
      ],
      model: "gpt-6-luna",
      provider: :openai,
      usage: AimHelm::Usage.new,
      stop_reason: :tool_use,
    )

    expect(message.text).to eq("working")
    expect(message.tool_calls).to contain_exactly(include("id" => "call_1"))
  end
end
