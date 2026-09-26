# frozen_string_literal: true

RSpec.describe "AimHelm live providers", :live do
  {
    "gpt-6-luna" => "OPENAI_API_KEY",
    "claude-opus-5-5" => "ANTHROPIC_API_KEY",
  }.each do |model, key|
    it "streams a short turn through #{model}" do
      require_live!(key)

      provider = AimHelm.provider(model)
      message = provider.stream(messages: [AimHelm::Message.user("Reply with OK")])

      expect(message.text).not_to be_empty
    ensure
      provider&.close
    end

    it "completes a tool round trip through #{model}" do
      require_live!(key)
      calls = []
      schema = AimHelm::Schema.define do
        required(:value).filled(:string)
      end
      tool = AimHelm::Tool.define("echo_value", "Echoes one value", schema:) do |arguments|
        calls << arguments.fetch("value")
        arguments.fetch("value")
      end
      options = AimHelm::Agent.new(
        instructions: "Call echo_value exactly once with value ping, then report its result.",
        model:,
        reasoning: :low,
        tools: [tool],
      )

      Dir.mktmpdir("aim_helm-live") do |dir|
        session = AimHelm::Session.new(store: AimHelm::Stores::JSONL.new(dir:))
        result = options.run("Run the required tool.", session:)

        expect(result.text).not_to be_empty
        expect(calls).to eq(["ping"])
      end
    end
  end

  it "accepts adaptive thinking with structured output through claude-opus-5-5" do
    require_live!("ANTHROPIC_API_KEY")
    schema = {
      type: "object",
      properties: { answer: { type: "string", enum: ["OK"] } },
      required: ["answer"],
      additionalProperties: false,
    }
    provider = AimHelm.provider("claude-opus-5-5", reasoning: :low)

    message = provider.stream(
      messages: [AimHelm::Message.user("Return OK in the required structure.")],
      output_schema: schema,
    )

    expect(JSON.parse(message.text)).to eq("answer" => "OK")
  ensure
    provider&.close
  end

  it "writes and reads an Anthropic prompt cache through claude-opus-5-5" do
    require_live!("ANTHROPIC_API_KEY")
    nonce = SecureRandom.uuid_v7
    system = "Cache test #{nonce}. #{"Retain this stable context. " * 2_000}"
    messages = [AimHelm::Message.user("Reply only OK.")]
    provider = AimHelm.provider("claude-opus-5-5")

    first = provider.stream(system:, messages:)
    second = provider.stream(system:, messages:)

    expect(first.usage.cache_write_tokens).to be_positive
    expect(second.usage.cached_input_tokens).to be_positive
  ensure
    provider&.close
  end

  def require_live!(key)
    skip "set AIM_HELM_LIVE=1 to make provider requests" unless ENV["AIM_HELM_LIVE"] == "1"
    skip "set #{key}" unless ENV[key]
  end
end
