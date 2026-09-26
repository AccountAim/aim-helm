# frozen_string_literal: true

RSpec.describe AimHelm::Providers::Anthropic do
  let(:model) { "claude-opus-5-5" }
  let(:records) { sse_records("streams/anthropic_turn.sse") }

  it "maps an Anthropic refusal to a normal stop" do
    expect(AimHelm::Providers::Anthropic::Assembler::STOP_REASONS.fetch("refusal")).to eq(:stop)
  end

  it "assembles normalized events and preserves same-model replay fields" do
    assembler = AimHelm::Providers::Anthropic::Assembler.new(model:)
    events = []
    records.each { |record| assembler.feed(record) { |event| events << event } }

    message = assembler.finish { |event| events << event }
    expected_content = [
      {
        "type" => "thinking",
        "thinking" => "Use the weather tool.",
        "signature" => "sig_anthropic",
        "redacted" => false,
      },
      { "type" => "text", "text" => "Checking now." },
      {
        "type" => "tool_call",
        "id" => "toolu_123",
        "name" => "weather",
        "arguments" => { "city" => "Seattle" },
      },
    ]

    expected_events = %i[
      thinking.delta
      message.delta
      tool.discovered
      tool.delta
      tool.delta
      tool.requested
      usage.reported
      turn.completed
    ]

    expected_assistant = [
      {
        role: "assistant",
        content: [
          {
            type: "thinking",
            thinking: "Use the weather tool.",
            signature: "sig_anthropic",
          },
          { type: "text", text: "Checking now." },
          {
            type: "tool_use",
            id: "toolu_123",
            name: "weather",
            input: { "city" => "Seattle" },
          },
        ],
      },
    ]

    expect(message.content).to eq(expected_content)
    expect(message.usage.to_h).to eq(
      input_tokens: 10,
      output_tokens: 7,
      cached_input_tokens: 20,
      cache_write_tokens: 30,
      reasoning_tokens: 0,
    )

    expect(message.stop_reason).to eq(:tool_use)
    expect(events.map { |event| event.fetch(:type) }).to eq(expected_events)
    expect(events.filter_map { |event| event[:sequence] }).to eq([1, 2, 3, 4])
    expect(events.select { |event| event.fetch(:type) == :"tool.delta" }.last
      .fetch(:arguments)).to eq("city" => "Seattle")
    expect(AimHelm::Providers::Anthropic::Serializer.messages([message], model:))
      .to eq(expected_assistant)

    entry = session_entry(
      :assistant,
      {
        content: message.content,
        model: message.model,
        provider: message.provider,
        stop_reason: message.stop_reason,
      },
    )
    result = session_entry(
      :tool_result,
      { call_id: "toolu_123", output: "sunny", error: false },
      id: 2,
    )
    expect(AimHelm::Providers::Anthropic::Serializer.replay([entry, result], model:)).to eq(
      expected_assistant + [
        {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: "toolu_123",
              content: [{ type: "text", text: "sunny" }],
              is_error: false,
            },
          ],
        },
      ],
    )
  end

  it "downgrades thinking to text when the model changes" do
    message = AimHelm::Providers::Anthropic::Assembler.new(model:).then do |assembler|
      records.each { |record| assembler.feed(record) }
      assembler.finish
    end

    entry = session_entry(
      :assistant,
      {
        content: message.content,
        model: message.model,
        provider: message.provider,
        stop_reason: message.stop_reason,
      },
    )
    content = AimHelm::Providers::Anthropic::Serializer
              .replay([entry], model: "claude-sonnet-5")
              .first.fetch(:content)

    expect(content.first).to eq(type: "text", text: "Use the weather tool.")
  end

  it "serializes every recorded log prefix into valid Messages API history" do
    message = AimHelm::Providers::Anthropic::Assembler.new(model:).then do |assembler|
      records.each { |record| assembler.feed(record) }
      assembler.finish
    end
    entries = replay_fixture_entries(message)

    (0..entries.length).each do |length|
      history = AimHelm::Providers::Anthropic::Serializer.replay(entries.first(length), model:)
      expect_valid_history(history)
    end
  end

  it "groups consecutive tool results into one user turn" do
    results = [
      AimHelm::Message.tool(content: "sunny", tool_call_id: "toolu_1"),
      AimHelm::Message.tool(content: "failed", tool_call_id: "toolu_2", error: true),
    ]

    serialized = AimHelm::Providers::Anthropic::Serializer.messages(results, model:)
    expected = [
      {
        role: "user",
        content: [
          {
            type: "tool_result",
            tool_use_id: "toolu_1",
            content: [{ type: "text", text: "sunny" }],
            is_error: false,
          },
          {
            type: "tool_result",
            tool_use_id: "toolu_2",
            content: [{ type: "text", text: "failed" }],
            is_error: true,
          },
        ],
      },
    ]

    expect(serialized).to eq(expected)
  end

  it "serializes image tool results as tool_result image blocks" do
    image = AimHelm::Image.data("png-bytes", media_type: "image/png")
    message = AimHelm::Message.tool(content: ["caption", image], tool_call_id: "toolu_9")

    serialized = AimHelm::Providers::Anthropic::Serializer.messages([message], model:)

    expect(serialized).to eq(
      [
        {
          role: "user",
          content: [
            {
              type: "tool_result",
              tool_use_id: "toolu_9",
              content: [
                { type: "text", text: "caption" },
                {
                  type: "image",
                  source: {
                    type: "base64",
                    media_type: "image/png",
                    data: ["png-bytes"].pack("m0"),
                  },
                },
              ],
              is_error: false,
            },
          ],
        },
      ],
    )
  end

  it "adds explicit system and automatic last-message cache breakpoints" do
    transport = instance_double(AimHelm::Providers::Streaming::Transport)
    request = nil
    schema = { type: "object", properties: { answer: { type: "string" } } }
    tools = [{ name: "weather", description: "Get weather", input_schema: schema }]

    allow(AimHelm::Providers::Streaming::Transport).to receive(:new).and_return(transport)
    allow(transport).to receive(:stream_post) do |path, body:, headers:, &sink|
      request = { path:, body:, headers: }
      records.each { |record| sink.call(record) }
    end

    provider = described_class.new(api_key: "anthropic-key", model:, reasoning: :high)
    provider.stream(
      system: "Be concise",
      messages: [AimHelm::Message.user("Weather?")],
      tools:,
      output_schema: schema,
    )

    expect(request.fetch(:body)).to include(
      cache_control: { type: "ephemeral" },
      system: [
        { type: "text", text: "Be concise", cache_control: { type: "ephemeral" } },
      ],
      tools: [{ name: "weather", description: "Get weather", input_schema: schema }],
      thinking: { type: "adaptive", display: "summarized" },
      output_config: { effort: "high", format: { type: "json_schema", schema: } },
    )
  end

  it "retries an initial in-stream overload before anything is emitted" do
    transport = instance_double(AimHelm::Providers::Streaming::Transport)
    attempts = 0
    allow(AimHelm::Providers::Streaming::Transport).to receive(:new).and_return(transport)
    allow(transport).to receive(:stream_post) do |*, &sink|
      attempts += 1
      if attempts == 1
        sink.call("type" => "error", "error" => {
                    "type" => "overloaded_error", "message" => "busy"
                  })
      else
        records.each { |record| sink.call(record) }
      end
    end
    provider = described_class.new(
      api_key: "anthropic-key",
      model:,
      retry_policy: AimHelm::Providers::Streaming::RetryPolicy.new(
        attempts: 1,
        base_delay: 0,
        max_delay: 0,
      ),
    )

    message = provider.stream { nil }

    expect(message.text).to eq("Checking now.")
    expect(attempts).to eq(2)
  end

  it "does not retry after a normalized event reaches the caller" do
    transport = instance_double(AimHelm::Providers::Streaming::Transport)
    attempts = 0
    events = []
    allow(AimHelm::Providers::Streaming::Transport).to receive(:new).and_return(transport)
    allow(transport).to receive(:stream_post) do |*, &sink|
      attempts += 1
      sink.call("type" => "content_block_start", "content_block" => { "type" => "text" })
      sink.call("type" => "content_block_delta",
                "delta" => { "type" => "text_delta", "text" => "visible" })
      raise AimHelm::OverloadedError, "busy"
    end
    provider = described_class.new(
      api_key: "anthropic-key",
      model:,
      retry_policy: AimHelm::Providers::Streaming::RetryPolicy.new(
        attempts: 1,
        base_delay: 0,
        max_delay: 0,
      ),
    )

    expect do
      provider.stream { |event| events << event }
    end.to raise_error(AimHelm::OverloadedError, "busy")
    expect(events).to all(be_a(AimHelm::Event))
    expect(events.map(&:type)).to eq(%i[message.delta provider.failed])
    expect(attempts).to eq(1)
  end

  def expect_valid_history(history)
    messages = JSON.parse(JSON.generate(history))
    roles = messages.map { |message| message.fetch("role") }
    expect(roles.each_cons(2).any? { |left, right| left == right }).to be(false)

    pending = []
    messages.each do |message|
      message.fetch("content").each do |content|
        case content["type"]
        when "tool_use"
          pending << content.fetch("id")
        when "tool_result"
          expect(pending).to include(content.fetch("tool_use_id"))
          pending.delete(content.fetch("tool_use_id"))
        end
      end
    end
    expect(pending).to be_empty
  end
end
