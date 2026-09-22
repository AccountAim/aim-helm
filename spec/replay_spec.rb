# frozen_string_literal: true

RSpec.describe AimHelm::Replay do
  it "restores provider messages from durable transcript entries" do
    entries = [
      session_entry(:user, { content: [{ type: "text", text: "Weather?" }] }, id: 1),
      session_entry(
        :assistant,
        {
          content: [{ type: "tool_call", id: "call-1", name: "weather", arguments: {} }],
          model: "gpt-6-luna",
          provider: "openai",
          stop_reason: "tool_use",
          usage: { input_tokens: 3, output_tokens: 2, cost: 0.001 },
        },
        id: 2,
      ),
      session_entry(:tool_call, { id: "call-1", name: "weather" }, id: 3),
      session_entry(
        :tool_result,
        { call_id: "call-1", output: "sunny", error: false },
        id: 4,
      ),
      session_entry(:usage, { input_tokens: 1 }, id: 5),
    ]

    messages = described_class.messages(entries)

    expect(messages.map(&:role)).to eq(%i[user assistant tool])
    expect(messages[1]).to have_attributes(
      model: "gpt-6-luna",
      provider: :openai,
      stop_reason: :tool_use,
      usage: have_attributes(input_tokens: 3, output_tokens: 2),
    )
    expect(messages[2]).to have_attributes(
      text: "sunny",
      tool_call_id: "call-1",
      tool_error: false,
    )
  end

  it "synthesizes an error result for a dangling tool call" do
    assistant = session_entry(
      :assistant,
      {
        content: [{ type: "tool_call", id: "call-1", name: "weather", arguments: {} }],
        model: "gpt-6-luna",
        provider: "openai",
        stop_reason: "tool_use",
      },
    )

    result = described_class.messages([assistant]).last

    expect(result).to have_attributes(
      role: :tool,
      text: described_class::INTERRUPTED_TOOL_RESULT,
      tool_call_id: "call-1",
      tool_error: true,
    )
  end

  it "merges consecutive durable user entries" do
    entries = [
      session_entry(:user, { content: "First" }, id: 1),
      session_entry(:terminal, { outcome: "failed" }, id: 2),
      session_entry(:user, { content: "Second" }, id: 3),
    ]

    messages = described_class.messages(entries)

    expect(messages.map(&:role)).to eq([:user])
    expect(messages.first.text).to eq("FirstSecond")
  end

  it "replaces a compacted prefix with its durable summary" do
    entries = [
      session_entry(:user, { content: "Old question" }, id: 1),
      session_entry(
        :assistant,
        {
          content: "Old answer",
          model: "gpt-6-luna",
          provider: "openai",
          stop_reason: "stop",
        },
        id: 2,
      ),
      session_entry(
        :compaction,
        { summary: "The report was approved.", covers_through_entry_id: 2 },
        id: 3,
      ),
      session_entry(:user, { content: "Continue" }, id: 4),
    ]

    messages = described_class.messages(entries)

    expect(messages.map(&:role)).to eq([:user])
    expect(messages.first.text).to eq(
      "Earlier conversation summary:\nThe report was approved.Continue",
    )
  end
end
