# frozen_string_literal: true

RSpec.describe AimHelm::Providers::OpenAI do
  let(:model) { "gpt-6-sol" }
  let(:records) { sse_records("streams/openai_turn.sse") }

  it "assembles normalized events and replays exact same-model items" do
    assembler = AimHelm::Providers::OpenAI::Assembler.new(model:)
    events = []
    records.each { |record| assembler.feed(record) { |event| events << event } }

    message = assembler.finish { |event| events << event }
    done_items = records.filter_map do |record|
      record["item"] if record["type"] == "response.output_item.done"
    end

    expect(message.content.map { |block| block.fetch("type") }).to eq(
      %w[thinking text tool_call],
    )
    expect(message.tool_calls.first).to include(
      "id" => "call_123",
      "name" => "weather",
      "arguments" => { "city" => "Seattle" },
    )
    expect(message.usage.to_h).to eq(
      input_tokens: 50,
      output_tokens: 5,
      cached_input_tokens: 10,
      cache_write_tokens: 0,
      reasoning_tokens: 2,
    )

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

    expect(events.map { |event| event.fetch(:type) }).to eq(expected_events)
    expect(events.filter_map { |event| event[:sequence] }).to eq([1, 2, 3, 4])
    expect(events.select { |event| event.fetch(:type) == :"tool.delta" }.last
      .fetch(:arguments)).to eq("city" => "Seattle")
    expect(AimHelm::Providers::OpenAI::Serializer.input([message], model:)).to eq(done_items)

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
      { call_id: "call_123", output: "sunny", error: false },
      id: 2,
    )
    expect(AimHelm::Providers::OpenAI::Serializer.replay([entry, result], model:)).to eq(
      done_items + [{ type: "function_call_output", call_id: "call_123", output: "sunny" }],
    )
  end

  it "serializes image tool results as a function output content array" do
    image = AimHelm::Image.data("png-bytes", media_type: "image/png")
    message = AimHelm::Message.tool(content: ["caption", image], tool_call_id: "call_9")

    serialized = AimHelm::Providers::OpenAI::Serializer.input([message], model:)

    expect(serialized).to eq(
      [
        {
          type: "function_call_output",
          call_id: "call_9",
          output: [
            { type: "input_text", text: "caption" },
            { type: "input_image", image_url: "data:image/png;base64,#{["png-bytes"].pack("m0")}" },
          ],
        },
      ],
    )
  end

  it "drops provider items and renders reasoning as text when the model changes" do
    message = AimHelm::Providers::OpenAI::Assembler.new(model:).then do |assembler|
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
    serialized = AimHelm::Providers::OpenAI::Serializer.replay([entry], model: "gpt-5.6-terra")

    expect(serialized.first).to eq(
      type: "message",
      role: "assistant",
      content: [{ type: "output_text", text: "Use the weather tool." }],
    )
    function_call = serialized.find { |item| item[:type] == "function_call" }
    expect(function_call).to eq(
      type: "function_call",
      call_id: "call_123",
      name: "weather",
      arguments: "{\"city\":\"Seattle\"}",
    )
    expect(serialized.last).to eq(
      type: "function_call_output",
      call_id: "call_123",
      output: AimHelm::Replay::INTERRUPTED_TOOL_RESULT,
    )
  end

  it "serializes every recorded log prefix into valid Responses API history" do
    message = AimHelm::Providers::OpenAI::Assembler.new(model:).then do |assembler|
      records.each { |record| assembler.feed(record) }
      assembler.finish
    end
    entries = replay_fixture_entries(message)

    (0..entries.length).each do |length|
      history = AimHelm::Providers::OpenAI::Serializer.replay(entries.first(length), model:)
      expect_valid_history(history)
    end
  end

  it "builds Responses API tools, reasoning, and structured output" do
    transport = instance_double(AimHelm::Providers::Streaming::Transport)
    request = nil
    schema = { type: "object", properties: { answer: { type: "string" } } }
    tools = [{ name: "weather", description: "Get weather", input_schema: schema }]

    allow(AimHelm::Providers::Streaming::Transport).to receive(:new).and_return(transport)
    allow(transport).to receive(:stream_post) do |path, body:, headers:, &sink|
      request = { path:, body:, headers: }
      records.each { |record| sink.call(record) }
    end

    provider = described_class.new(api_key: "openai-key", model:, reasoning: :high)
    provider.stream(
      system: "Be concise",
      messages: [AimHelm::Message.user("Weather?")],
      tools:,
      output_schema: schema,
    )

    expect(request.fetch(:body)).to include(
      model:,
      instructions: "Be concise",
      store: false,
      include: ["reasoning.encrypted_content"],
      reasoning: { effort: "high", summary: "auto" },
      tools: [
        {
          type: "function",
          name: "weather",
          description: "Get weather",
          parameters: schema,
        },
      ],
      text: { format: { type: "json_schema", name: "output", strict: true, schema: } },
    )
  end

  it "retries raw stream activity before anything is emitted" do
    transport = instance_double(AimHelm::Providers::Streaming::Transport)
    attempts = 0
    allow(AimHelm::Providers::Streaming::Transport).to receive(:new).and_return(transport)
    allow(transport).to receive(:stream_post) do |*, &sink|
      attempts += 1
      if attempts == 1
        sink.call("type" => "response.created", "response" => { "id" => "resp_initial" })
        raise AimHelm::OverloadedError, "busy"
      end
      records.each { |record| sink.call(record) }
    end
    provider = described_class.new(
      api_key: "openai-key",
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
      sink.call("type" => "response.output_item.added",
                "item" => { "id" => "msg_initial", "type" => "message" })
      sink.call("type" => "response.output_text.delta", "delta" => "visible")
      raise AimHelm::OverloadedError, "busy"
    end
    provider = described_class.new(
      api_key: "openai-key",
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
    items = JSON.parse(JSON.generate(history))
    pending = []
    items.each do |item|
      case item["type"]
      when "function_call"
        pending << item.fetch("call_id")
      when "function_call_output"
        expect(pending).to include(item.fetch("call_id"))
        pending.delete(item.fetch("call_id"))
      end
    end

    expect(pending).to be_empty
    expect(items.each_cons(2).any? { |left, right| user?(left) && user?(right) }).to be(false)
  end

  def user?(item) = item["type"] == "message" && item["role"] == "user"
end
