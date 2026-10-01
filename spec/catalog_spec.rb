# frozen_string_literal: true

RSpec.describe AimHelm::Catalog::Model do
  let(:catalog) { YAML.safe_load_file(AimHelm::Catalog::CATALOG_PATH) }

  it "resolves every alias to a bundled model row" do
    catalog.fetch("aliases").each_key do |name|
      expect(catalog.fetch("models")).to have_key(AimHelm.models.fetch(name).id)
    end
  end

  describe "#cost" do
    let(:model) do
      described_class.new(
        id: "test", provider: :openai, input: 2.0, output: 10.0, cached_input: 0.2,
        cache_write: 1.0, context: 1_000_000, max_output: 1_000, reasoning_effort: true,
        vision: true,
        long_context: {
          above: 1_300, input: 4.0, output: 15.0, cached_input: 0.4, cache_write: 2.0
        }
      )
    end

    def usage(input_tokens)
      AimHelm::Usage.new(
        input_tokens:,
        output_tokens: 500,
        cached_input_tokens: 200,
        cache_write_tokens: 100,
      )
    end

    it "prices regular, cached, and cache-write tokens per million" do
      expect(model.cost(usage(1_000))).to eq(0.00714)
    end

    it "bills the whole call at long-context rates once the prompt passes the threshold" do
      expect(model.cost(usage(1_001))).to eq(0.011784)
    end
  end

  it "loads host aliases over an existing catalog" do
    Dir.mktmpdir("aim_helm-models") do |dir|
      path = File.join(dir, "models.yml")
      File.write(
        path,
        YAML.dump("models" => {}, "aliases" => { "old" => "fast", "fast" => "gpt-latest-luna" }),
      )

      catalog = AimHelm::Catalog.load(path, base: AimHelm.models)
      luna = AimHelm.models.fetch("gpt-latest-luna").id

      expect(catalog.fetch("fast")).to have_attributes(id: luna, provider: :openai)
      expect(catalog.fetch("old")).to have_attributes(id: luna)
      expect(catalog).to be_frozen
    end
  end
end
