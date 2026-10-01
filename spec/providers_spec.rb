# frozen_string_literal: true

RSpec.describe AimHelm::Providers do
  it "infers the provider from the allowlisted model" do
    expect(AimHelm.provider("gpt-latest-sol", api_key: "key")).to be_a(AimHelm::Providers::OpenAI)
    expect(AimHelm.provider("claude-latest-opus", api_key: "key")).to be_a(
      AimHelm::Providers::Anthropic,
    )
  end

  it "rejects unknown models" do
    expect do
      AimHelm.provider("old-model", api_key: "key")
    end.to raise_error(AimHelm::ConfigurationError, /unknown model/)
  end

  it "rejects generic reasoning effort for Haiku" do
    expect do
      AimHelm.provider("claude-latest-haiku", api_key: "key", reasoning: :high)
    end.to raise_error(AimHelm::ConfigurationError, /does not support reasoning effort/)
  end
end
