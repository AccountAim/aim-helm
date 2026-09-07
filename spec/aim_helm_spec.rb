# frozen_string_literal: true

RSpec.describe AimHelm do
  it "loads without Rails" do
    expect(defined?(Rails)).to be_nil
  end

  it "accepts a host logger" do
    logger = Class.new { def error(*) = nil }.new
    previous_logger = described_class.config.logger

    described_class.configure { |config| config.logger = logger }

    expect(described_class.config.logger).to equal(logger)
  ensure
    described_class.configure { |config| config.logger = previous_logger }
  end

  it "eager loads every canonical constant" do
    expect { Zeitwerk::Loader.eager_load_all }.not_to raise_error
  end

  it "resolves host-defined providers from an extended catalog" do
    model = AimHelm.models.fetch("gpt-5.6-luna").new(
      id: "gateway-luna",
      provider: :gateway,
    )
    calls = []
    config = AimHelm.config.with(
      model_catalog: AimHelm.models.merge(model.id => model).freeze,
      providers: {
        gateway: { api_key: "test-key", base_url: "https://gateway.example" },
      },
      provider_factory: lambda do |model_id, **attributes|
        calls << [model_id, attributes]
        :provider
      end,
    )

    provider = described_class.provider(model.id, config:, reasoning: :low)

    expect(provider).to eq(:provider)
    expect(calls).to contain_exactly(
      [
        model.id,
        hash_including(
          api_key: "test-key",
          base_url: "https://gateway.example",
          catalog: config.model_catalog,
          reasoning: :low,
        ),
      ],
    )
  end
end
