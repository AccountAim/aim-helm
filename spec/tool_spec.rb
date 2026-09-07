# frozen_string_literal: true

RSpec.describe AimHelm::Tool do
  let(:schema) do
    AimHelm::Schema.define do
      required(:report_id).filled(:integer)
    end
  end

  it "validates, coerces, and string-keys handler arguments" do
    received = nil
    tool = described_class.define(
      "lookup",
      "Looks up a report",
      identifier: "analysis/lookup",
      schema:,
    ) do |arguments, _context|
      received = arguments
      "Report ready"
    end

    result = tool.call({ "report_id" => 7, "ignored" => true }, context: Object.new)

    expect(result).to eq("Report ready")
    expect(received).to eq("report_id" => 7)
    expect(tool.identifier).to eq("analysis/lookup")
    expect(tool.spec.fetch(:input_schema)).to include(
      "type" => "object",
      "required" => ["report_id"],
    )
  end

  it "rejects arguments that violate the schema" do
    tool = described_class.define("lookup", "Looks up a report", schema:) { nil }

    expect { tool.call({}, context: Object.new) }
      .to raise_error(ArgumentError, /report_id/)
  end

  it "uses an empty Dry::Schema contract when schema is omitted" do
    received = nil
    tool = described_class.define("ping", "Pings") do |arguments, _context|
      received = arguments
    end

    tool.call({ "call" => "shadow" }, context: Object.new)

    expect(received).to eq({})
  end

  it "evaluates callable approval policies with validated arguments" do
    received = nil
    tool = described_class.define(
      "lookup",
      "Looks up a report",
      schema:,
      requires_approval: lambda do |arguments, context|
        received = [arguments, context]
        arguments.fetch("report_id") == 7
      end,
    ) { nil }

    context = Object.new
    expect(tool.approval_required?(tool.prepare(report_id: 7, ignored: true), context:)).to be(true)
    expect(received).to eq([{ "report_id" => 7 }, context])
    expect(tool.approval_required?(tool.prepare("report_id" => 8), context:)).to be(false)
  end

  it "returns explicit model-actionable failures with host metadata" do
    result = described_class::Result.failure(
      content: "Report is missing",
      metadata: { report_id: "report-1" },
    )

    expect(result).to be_failure
    expect(result.content).to eq("Report is missing")
    expect(result.metadata).to eq("report_id" => "report-1")
  end
end
