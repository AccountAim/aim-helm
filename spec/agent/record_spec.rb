# frozen_string_literal: true

RSpec.describe AimHelm::Agent::Record do
  let(:output_schema) do
    AimHelm::Schema.define do
      required(:answer).filled(:string)
    end
  end

  let(:options) do
    AimHelm::Agent.new(
      instructions: "Answer accurately.",
      model: "gpt-5.6-luna",
      reasoning: :medium,
      output: output_schema,
      max_turns: 8,
      budget: AimHelm::Budget.new(tokens: 100_000, cost: 2, wall_clock: 300),
      compaction: AimHelm::Compaction.new(
        model: "gpt-5.6-luna",
        threshold: 0.6,
        system: "Summarize precisely.",
      ),
      reminders: [AimHelm::Reminder.new(text: "Stay focused.", every: 3, after: 1)],
    )
  end

  it "round-trips a handler-free options definition" do
    record = described_class.capture(options:, tools: ["analysis/lookup"])
    restored = described_class.deserialize(record.dump)
    tool = AimHelm::Tool.define("lookup", "Looks up a report") { "ready" }

    expect(restored).to have_attributes(
      version: 1,
      system: options.instructions,
      model: options.model,
      reasoning: :medium,
      tools: ["analysis/lookup"],
      output_schema: AimHelm::Types::JsonObject[output_schema.json_schema],
      max_iterations: 8,
      budget: have_attributes(tokens: 100_000, cost: 2.0, wall_clock: 300.0),
      compaction: have_attributes(
        model: "gpt-5.6-luna",
        threshold: 0.6,
        system: "Summarize precisely.",
      ),
      reminders: [have_attributes(text: "Stay focused.", every: 3, after: 1)],
    )
    expect(restored.materialize(tools: [tool])).to have_attributes(
      instructions: options.instructions,
      model: options.model,
      tools: [tool],
      budget: options.budget,
      compaction: options.compaction,
      reminders: options.reminders,
      output: have_attributes(
        json_schema: AimHelm::Types::JsonObject[output_schema.json_schema],
      ),
    )
  end

  it "requires authored result contracts to use Dry::Schema" do
    expect do
      options.new(output: { type: "object" })
    end.to raise_error(Dry::Struct::Error)

    expect do
      AimHelm::Subagent.new(
        name: "researcher",
        description: "Researches one question",
        system: "Research carefully.",
        output_schema: { type: "object" },
      )
    end.to raise_error(Dry::Struct::Error)
  end

  it "rejects unknown and missing record fields" do
    record = described_class.capture(options:, tools: []).dump

    expect { described_class.deserialize(record.merge("extra" => true)) }
      .to raise_error(AimHelm::TamperedRecordError, /extra/)
    expect { described_class.deserialize(record.except("model")) }
      .to raise_error(AimHelm::TamperedRecordError, /model/)
    expect do
      described_class.deserialize(record.merge("budget" => { "requests" => 2 }))
    end.to raise_error(AimHelm::TamperedRecordError, /requests/)
    expect do
      reminder = { "text" => "Focus", "every" => 0 }
      described_class.deserialize(record.merge("reminders" => [reminder]))
    end.to raise_error(AimHelm::TamperedRecordError)
  end

  it "finds the record for one durable turn" do
    entry = session_entry(:run_record, described_class.capture(options:, tools: []).dump)

    expect(described_class.fetch([entry], run_id: "turn-1").model).to eq(options.model)
    expect { described_class.fetch([entry], run_id: "turn-2") }
      .to raise_error(AimHelm::TamperedRecordError, /turn-2/)
  end

  it "round-trips subagent definitions without runtime handlers" do
    definition = AimHelm::Subagent.new(
      name: "researcher",
      description: "Researches one question",
      system: "Research carefully.",
      model: "gpt-5.6-luna",
      tools: ["reports/lookup"],
      output_schema:,
      max_iterations: 4,
      budget: AimHelm::Budget.new(tokens: 20_000),
    )
    configured = options.new(subagents: [definition])

    restored = described_class.deserialize(
      described_class.capture(options: configured, tools: []).dump,
    )

    expect(restored.subagents).to contain_exactly(
      have_attributes(
        name: "researcher",
        system: "Research carefully.",
        tools: ["reports/lookup"],
        output_schema: have_attributes(
          json_schema: AimHelm::Types::JsonObject[output_schema.json_schema],
        ),
        max_iterations: 4,
        budget: have_attributes(tokens: 20_000),
      ),
    )
    expect(restored.materialize(tools: []).subagents?).to be(true)
  end

  it "round-trips an open dynamic subagent grant" do
    tool = AimHelm::Tool.define(
      "lookup",
      description: "Looks up a report",
      identifier: "reports/lookup",
    ) { "ready" }
    grant = AimHelm::Subagent.open(tools: [tool], modes: [:background])
    configured = options.new(tools: [tool], subagents: [grant])

    restored = described_class.deserialize(
      described_class.capture(options: configured).dump,
    )

    expect(restored.subagents).to contain_exactly(
      have_attributes(open: true, tools: ["reports/lookup"], modes: [:background]),
    )
  end
end
