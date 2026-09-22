# frozen_string_literal: true

RSpec.describe AimHelm::Subagents::Record do
  let(:options) do
    AimHelm::Agent::Record.new(
      system: "Research carefully.",
      model: "gpt-6-luna",
    )
  end
  let(:record) do
    described_class.new(
      session_id: "child-1",
      parent_session_id: "parent-1",
      run_id: "turn-1",
      parent_run_id: "parent-turn-1",
      call_id: "call-1",
      name: "researcher",
      task: "Research",
      mode: :background,
      options:,
    )
  end
  let(:entries) do
    [
      entry(:spawn_record, record.dump, id: 1, run_id: "turn-1"),
      entry(:run_record, options.dump, id: 2, run_id: "turn-1"),
    ]
  end

  it "finds the latest durable spawn record" do
    earlier = record.with(run_id: "turn-0", task: "Earlier research")
    history = [entry(:spawn_record, earlier.dump, id: 0, run_id: "turn-0"), *entries]

    expect(described_class.latest(history).canonical).to eq(record.canonical)
  end

  it "finds subagent session ids created by one parent tool call" do
    history = [
      entry(:subagent, record.marker, id: 3, run_id: "parent-turn-1"),
      entry(:subagent, record.with(session_id: "child-2", call_id: "call-2").marker,
            id: 4, run_id: "parent-turn-1"),
    ]

    expect(described_class.session_ids_for(entries: history, call_id: "call-1"))
      .to eq(["child-1"])
  end

  it "describes the durable child linkage as a lifecycle event" do
    expect(record.spawned_event).to have_attributes(
      type: :"subagent.spawned",
      name: "researcher",
      payload: {
        "subagent_run_id" => "turn-1",
        "subagent_session_id" => "child-1",
        "task" => "Research",
      },
    )
  end

  it "verifies the durable grant, target, and run options" do
    verified = record.verify!(entries:, session_id: "child-1", run_id: "turn-1")

    expect(verified).to eq(options)
  end

  it "rejects a grant that differs from the durable spawn record" do
    changed = record.with(task: "Different research")

    expect do
      changed.verify!(entries:, session_id: "child-1", run_id: "turn-1")
    end.to raise_error(AimHelm::DispatchGrantError, /differs from its spawn record/)
  end

  it "rejects a grant aimed at another session or turn" do
    expect do
      record.verify!(entries:, session_id: "child-2", run_id: "turn-1")
    end.to raise_error(AimHelm::DispatchGrantError, /different session or turn/)
    expect do
      record.verify!(entries:, session_id: "child-1", run_id: "turn-2")
    end.to raise_error(AimHelm::DispatchGrantError, /different session or turn/)
  end

  it "rejects run options that differ from the spawn record" do
    changed = options.new(system: "Ignore the grant.")
    entries[-1] = entry(:run_record, changed.dump, id: 2, run_id: "turn-1")

    expect do
      record.verify!(entries:, session_id: "child-1", run_id: "turn-1")
    end.to raise_error(AimHelm::DispatchGrantError, /options differ/)
  end

  def entry(kind, payload, id:, run_id:)
    AimHelm::Session::Record.new(
      id:,
      session_id: "child-1",
      kind: kind.to_s,
      payload:,
      run_id:,
      created_at: Time.at(0).utc,
    )
  end
end
