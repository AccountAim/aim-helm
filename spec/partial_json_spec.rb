# frozen_string_literal: true

RSpec.describe AimHelm::Providers::Streaming::PartialJSON do
  it "keeps completed values from an incomplete object" do
    expect(described_class.parse('{"query":"sea')).to eq("query" => "sea")
    expect(described_class.parse('{"items":[1,2')).to eq("items" => [1, 2])
    expect(described_class.parse('{"ready":tru')).to eq("ready" => true)
  end

  it "returns an empty object for unusable or excessively nested input" do
    expect(described_class.parse('{"dangling"')).to eq({})
    expect(described_class.parse("[" * 300)).to eq({})
  end
end
