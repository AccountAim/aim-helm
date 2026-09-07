# frozen_string_literal: true

RSpec.describe AimHelm::Budget do
  it "reconstructs lifetime spend and reports the first exhausted limit" do
    entries = [
      session_entry(
        :usage,
        {
          input_tokens: 6,
          output_tokens: 2,
          cached_input_tokens: 1,
          cache_write_tokens: 1,
          cost: 0.25,
          wall_clock: 2.0,
        },
        id: 1,
      ),
      session_entry(
        :assistant,
        {
          content: "Done",
          usage: { input_tokens: 2, output_tokens: 1, cost: 0.1, wall_clock: 1.0 },
        },
        id: 2,
      ),
    ]
    budget = described_class.new(tokens: 12, cost: 1, wall_clock: 10)

    expect(budget.exhaustion(entries, live_wall_clock: 0.5)).to eq(
      "limit" => { "tokens" => 12, "cost" => 1.0, "wall_clock" => 10.0 },
      "spent" => { "tokens" => 13, "cost" => 0.35, "wall_clock" => 3.5 },
      "exceeded" => "tokens",
    )
  end

  it "narrows each inherited limit independently" do
    parent = described_class.new(tokens: 100, cost: 2, wall_clock: 30)
    child = described_class.new(tokens: 40, cost: 3)

    expect(parent.narrow(child)).to have_attributes(tokens: 40, cost: 2.0, wall_clock: 30.0)
  end

  it "rejects unknown and non-positive durable limits" do
    expect { described_class.deserialize("requests" => 2) }
      .to raise_error(AimHelm::TamperedRecordError, /requests/)
    expect { described_class.deserialize("tokens" => 0) }
      .to raise_error(AimHelm::TamperedRecordError)
  end
end
