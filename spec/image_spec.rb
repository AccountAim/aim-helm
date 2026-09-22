# frozen_string_literal: true

RSpec.describe AimHelm::Providers::Image do
  it "maps URL, base64, and provider file sources to native image inputs" do
    url = described_class.from(
      "type" => "image",
      "source" => { "type" => "url", "url" => "https://example.com/chart.png" },
      "detail" => "high",
    )
    encoded = described_class.from(
      "type" => "image",
      "source" => { "type" => "base64", "media_type" => "image/png", "data" => "abc" },
    )
    openai_file = described_class.from(
      "type" => "image",
      "source" => { "type" => "file", "provider" => "openai", "file_id" => "file-oai" },
    )
    anthropic_file = described_class.from(
      "type" => "image",
      "source" => { "type" => "file", "provider" => "anthropic", "file_id" => "file-ant" },
    )

    expect(url.openai).to eq(
      type: "input_image",
      detail: "high",
      image_url: "https://example.com/chart.png",
    )
    expect(url.anthropic).to eq(
      type: "image",
      source: { type: "url", url: "https://example.com/chart.png" },
    )
    expect(encoded.openai.fetch(:image_url)).to eq("data:image/png;base64,abc")
    expect(openai_file.openai).to eq(type: "input_image", file_id: "file-oai")
    expect(anthropic_file.anthropic).to eq(
      type: "image",
      source: { type: "file", file_id: "file-ant" },
    )
  end

  it "rejects a provider-bound file on the other wire" do
    image = described_class.from(
      "type" => "image",
      "source" => { "type" => "file", "provider" => "openai", "file_id" => "file-oai" },
    )

    expect { image.anthropic }.to raise_error(AimHelm::ConfigurationError, /openai file/)
  end
end

RSpec.describe "AimHelm image input" do
  it "exposes the encoded bytes and media type of a data image" do
    image = AimHelm::Image.data("png-bytes", media_type: "image/png")

    expect(image.data).to eq(["png-bytes"].pack("m0"))
    expect(image.media_type).to eq("image/png")
    expect(AimHelm::Image.url("https://example.com/image.png").data).to be_nil
  end

  around do |example|
    Dir.mktmpdir("aim_helm-images") do |dir|
      @session = AimHelm::Session.new(store: AimHelm::Stores::JSONL.new(dir:), id: "session-1")
      example.run
    end
  end

  it "normalizes one native image block without turning its hash into pairs" do
    message = AimHelm::Message.user(image("https://example.com/only.png"))

    expect(message.content).to eq(
      [
        {
          "type" => "image",
          "source" => {
            "type" => "url",
            "url" => "https://example.com/only.png",
          },
        },
      ],
    )
  end

  it "authors typed URL, data, and provider-file images" do
    input = AimHelm::Input.new(
      text: "Compare these.",
      attachments: [
        AimHelm::Image.url("https://example.com/chart.png", detail: :high),
        AimHelm::Image.data("png", media_type: "image/png"),
        AimHelm::Image.provider_file(provider: :openai, id: "file-1"),
      ],
    )

    content = AimHelm::Message.user(input).content

    expect(content.first).to eq("type" => "text", "text" => "Compare these.")
    expect(content.fetch(1)).to include(
      "type" => "image",
      "detail" => "high",
      "source" => include("type" => "url"),
    )
    expect(content.fetch(2).dig("source", "data")).to eq(["png"].pack("m0"))
    expect(content.fetch(3).fetch("source")).to include(
      "type" => "file",
      "provider" => "openai",
      "file_id" => "file-1",
    )
  end

  it "rejects values that are neither text nor content blocks" do
    expect { AimHelm::Message.user(nil) }.to raise_error(Dry::Struct::Error, /String or Hash/)
    expect { AimHelm::Message.user(42) }.to raise_error(Dry::Struct::Error, /String or Hash/)
  end

  it "round-trips native image blocks through requests and the queued-message fold" do
    record = AimHelm::Agent::Record.new(system: "Inspect images.", model: "gpt-6-luna")
    control = AimHelm::Control.new(session: @session)
    first = image("https://example.com/first.png")
    second = image("https://example.com/second.png")
    control.start(prompt: [first, { type: "text", text: "Compare this." }], record:,
                  run_id: "turn-1")
    @session.append(:terminal, { outcome: :done }, key: "terminal:turn-1", run_id: "turn-1")
    control.queue_message(content: [second, { type: "text", text: "Now this one." }], key: "m-1")
    control.continue_queued(run_id: "turn-2")

    messages = AimHelm::Replay.messages(@session.entries)
    sources = messages.flat_map(&:content).filter_map do |block|
      block.dig("source", "url") if block["type"] == "image"
    end
    expect(sources).to eq(
      ["https://example.com/first.png", "https://example.com/second.png"],
    )
    expect(AimHelm::Providers::OpenAI::Serializer.input(messages, model: record.model)
      .flat_map { |item| Array(item[:content]) }
      .select { |item| item[:type] == "input_image" }
      .map { |item| item[:image_url] }).to eq(sources)
    expect(AimHelm::Providers::Anthropic::Serializer.messages(messages, model: record.model)
      .flat_map { |message| message.fetch(:content) }
      .select { |item| item[:type] == "image" }
      .map { |item| item.dig(:source, :url) }).to eq(sources)
  end

  def image(url)
    { type: "image", source: { type: "url", url: } }
  end
end
