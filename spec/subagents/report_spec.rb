# frozen_string_literal: true

RSpec.describe AimHelm::Subagents::Report do
  let(:record) do
    AimHelm::Subagents::Record.new(
      session_id: "child-1",
      parent_session_id: "parent-1",
      run_id: "turn-1",
      parent_run_id: "parent-turn-1",
      call_id: "call-1",
      name: "researcher",
      task: "Research",
      mode: :background,
      options: AimHelm::Agent::Record.new(
        system: "Research carefully.",
        model: "gpt-5.6-luna",
      ),
    )
  end
  let(:assistant) do
    {
      content: [{ type: "text", text: "Research complete" }],
      model: "gpt-5.6-luna",
      provider: :openai,
      stop_reason: :stop,
    }
  end

  it "reconstructs a terminal child report from its turn entries" do
    entries = [
      entry(:assistant, assistant, id: 1),
      entry(:terminal, { outcome: :done }, id: 2),
    ]

    report = described_class.from(entries:, record:)

    expect(report).to have_attributes(
      id: "child-1",
      name: "researcher",
      status: :completed,
      text: "Research complete",
      error: nil,
      terminal_entry_id: "2",
    )
  end

  it "does not build a report before the child reaches a terminal" do
    expect(described_class.from(entries: [entry(:assistant, assistant, id: 1)], record:)).to be_nil
  end

  def entry(kind, payload, id:)
    AimHelm::Session::Record.new(
      id:,
      session_id: "child-1",
      kind: kind.to_s,
      payload:,
      run_id: "turn-1",
      created_at: Time.at(0).utc,
    )
  end
end
