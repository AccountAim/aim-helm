# frozen_string_literal: true

RSpec.describe AimHelm::Catalog::Model do
  it "loads the current allowlist and resolves retired ids to their successors" do
    expect(AimHelm.models.keys).to contain_exactly(
      "claude-fable-5-1",
      "claude-haiku-4-5",
      "claude-opus-5-5",
      "claude-sonnet-5",
      "claude-latest-fable",
      "claude-latest-opus",
      "claude-latest-sonnet",
      "claude-latest-haiku",
      "gpt-latest-astra",
      "gpt-latest-sol",
      "gpt-latest-luna",
      "gpt-latest-terra",
      "gpt-5.6-sol",
      "gpt-5.6-luna",
      "gpt-5.6-terra",
      "gpt-6-astra",
      "gpt-6-luna",
      "gpt-6-sol",
    )
    expect(AimHelm.models.fetch("gpt-5.6-sol").id).to eq("gpt-6-sol")
    expect(AimHelm.models.fetch("gpt-latest-sol").id).to eq("gpt-6-sol")
  end

  it "carries the flagship's rates and limits" do
    expect(AimHelm.models.fetch("gpt-6-astra")).to have_attributes(
      provider: :openai, input: 10.0, cached_input: 1.0, output: 50.0, cache_write: 0.0,
      context: 1_050_000, max_output: 128_000, reasoning_effort: true, vision: true
    )
  end

  it "prices regular and cached tokens without charging OpenAI cache writes" do
    usage = AimHelm::Usage.new(
      input_tokens: 1_000,
      output_tokens: 500,
      cached_input_tokens: 200,
      cache_write_tokens: 100,
    )

    expect(AimHelm.models.fetch("gpt-6-sol").cost(usage)).to eq(0.00704)
  end

  it "keeps every OpenAI cache-write rate at zero" do
    openai = AimHelm.models.values.select { it.provider == :openai }
    expect(openai).not_to be_empty
    expect(openai.map(&:cache_write)).to all(eq(0.0))
  end

  it "loads host aliases over an existing catalog" do
    Dir.mktmpdir("aim_helm-models") do |dir|
      path = File.join(dir, "models.yml")
      File.write(
        path,
        YAML.dump("models" => {}, "aliases" => { "fast" => "gpt-6-luna" }),
      )

      catalog = AimHelm::Catalog.load(path, base: AimHelm.models)

      expect(catalog.fetch("fast")).to have_attributes(id: "gpt-6-luna", provider: :openai)
      expect(catalog).to be_frozen
    end
  end
end
