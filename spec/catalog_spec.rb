# frozen_string_literal: true

RSpec.describe AimHelm::Catalog::Model do
  it "loads the current allowlist and resolves the default GPT alias" do
    expect(AimHelm.models.keys).to contain_exactly(
      "claude-fable-5",
      "claude-haiku-4-5",
      "claude-mythos-5",
      "claude-opus-5",
      "claude-sonnet-5",
      "gpt-5.6",
      "gpt-5.6-luna",
      "gpt-5.6-sol",
      "gpt-5.6-terra",
    )
    expect(AimHelm.models.fetch("gpt-5.6").input).to eq(5.0)
  end

  it "prices regular and cached tokens without charging OpenAI cache writes" do
    usage = AimHelm::Usage.new(
      input_tokens: 1_000,
      output_tokens: 500,
      cached_input_tokens: 200,
      cache_write_tokens: 100,
    )

    expect(AimHelm.models.fetch("gpt-5.6-sol").cost(usage)).to eq(0.0201)
  end

  it "keeps GPT-5.6 cache-write rates at zero" do
    %w[gpt-5.6-sol gpt-5.6-terra gpt-5.6-luna].each do |id|
      expect(AimHelm.models.fetch(id).cache_write).to eq(0.0)
    end
  end

  it "loads host aliases over an existing catalog" do
    Dir.mktmpdir("aim_helm-models") do |dir|
      path = File.join(dir, "models.yml")
      File.write(
        path,
        YAML.dump("models" => {}, "aliases" => { "fast" => "gpt-5.6-luna" }),
      )

      catalog = AimHelm::Catalog.load(path, base: AimHelm.models)

      expect(catalog.fetch("fast")).to have_attributes(id: "fast", provider: :openai)
      expect(catalog).to be_frozen
    end
  end
end
