# frozen_string_literal: true

RSpec.describe AimHelm::Tools::Resolver do
  let(:tool) do
    AimHelm::Tool.define(
      "lookup",
      "Looks up a report",
      identifier: "report_tools/lookup",
    ) { "ready" }
  end

  let(:namespace) do
    Module.new.tap do |root|
      tools = Module.new
      root.const_set(:ReportTools, tools)
      tools.const_set(:Lookup, tool)
    end
  end

  subject(:resolver) { described_class.new(namespace:) }

  it "resolves nested tool identifiers without Active Support" do
    expect(resolver.resolve("report_tools/lookup")).to equal(tool)
    expect(resolver.identifiers([tool, "report_tools/lookup"]))
      .to eq(%w[report_tools/lookup report_tools/lookup])
  end

  it "rejects unknown and non-tool constants" do
    namespace.const_set(:Other, Object.new)

    expect { resolver.resolve("missing") }
      .to raise_error(AimHelm::ConfigurationError, /unknown registered tool/)
    expect { resolver.resolve("other") }
      .to raise_error(AimHelm::ConfigurationError, /is not a AimHelm::Tool/)
  end

  it "does not misclassify errors raised while loading a registered tool" do
    allow(namespace).to receive(:const_defined?).with("Broken", false).and_return(true)
    allow(namespace).to receive(:const_get)
      .with("Broken", false)
      .and_raise(NameError, "missing dependency")

    expect { resolver.resolve("broken") }.to raise_error(NameError, /missing dependency/)
  end
end
