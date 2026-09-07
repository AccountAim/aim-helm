# frozen_string_literal: true

RSpec.describe AimHelm::Control do
  around do |example|
    Dir.mktmpdir("aim_helm-control") do |dir|
      @store = AimHelm::Stores::JSONL.new(dir:)
      example.run
    end
  end

  let(:session) { AimHelm::Session.new(store: @store, id: "session-1") }
  let(:control) { described_class.new(session:) }
  let(:record) do
    AimHelm::Agent::Record.new(
      system: "Answer accurately.",
      model: "gpt-5.6-luna",
    )
  end

  it "starts and reads one durable turn" do
    control.start(prompt: "Summarize", record:, run_id: "turn-1")

    expect(control.read).to include(id: "session-1", status: :queued)
    expect(session.entries).to match(
      [
        have_attributes(kind: "run_record", key: "run:turn-1", run_id: "turn-1"),
        have_attributes(
          kind: "user",
          key: "user:turn-1",
          run_id: "turn-1",
          payload: { "content" => [{ "type" => "text", "text" => "Summarize" }] },
        ),
      ],
    )
  end

  it "starts a child from its durable spawn record" do
    spawn = AimHelm::Subagents::Record.new(
      session_id: "session-1",
      parent_session_id: "parent-1",
      run_id: "turn-1",
      parent_run_id: "parent-turn-1",
      call_id: "call-1",
      name: "researcher",
      task: "Research",
      mode: :background,
      options: record,
    )

    control.start_subagent(record: spawn)

    expect(session.entries.map(&:kind)).to eq(%w[spawn_record run_record user])
    expect(session.entries.first).to have_attributes(
      key: "spawn:turn-1",
      payload: spawn.dump,
      run_id: "turn-1",
    )
  end

  it "continues a completed session from its queued messages" do
    control.start(prompt: "First", record:, run_id: "turn-1")
    session.append(:terminal, { outcome: :done }, key: "terminal:turn-1", run_id: "turn-1")
    control.queue_message(content: "Second", key: "message:1")

    control.continue_queued(run_id: "turn-2")

    expect(session.pending_messages).to be_empty
    expect(session.entries.last(2)).to match(
      [
        have_attributes(kind: "run_record", key: "run:turn-2", run_id: "turn-2"),
        have_attributes(
          kind: "user",
          key: a_string_matching(/messages:/),
          run_id: "turn-2",
          payload: hash_including(
            "content" => [{ "type" => "text", "text" => "Second" }],
          ),
        ),
      ],
    )
  end

  it "carries a subagent grant into every continued turn" do
    spawn = AimHelm::Subagents::Record.new(
      session_id: "session-1",
      parent_session_id: "parent-1",
      run_id: "turn-1",
      parent_run_id: "parent-turn-1",
      call_id: "call-1",
      name: "researcher",
      task: "Research",
      mode: :background,
      options: record,
    )
    control.start_subagent(record: spawn)
    session.append(:terminal, { outcome: :done }, key: "terminal:turn-1", run_id: "turn-1")
    control.queue_message(content: "Check the correction")

    control.continue_queued(run_id: "turn-2")

    continued = AimHelm::Subagents::Record.fetch(session.entries, run_id: "turn-2")
    expect(continued).to have_attributes(
      run_id: "turn-2",
      task: [{ "type" => "text", "text" => "Check the correction" }],
      mode: :background,
      options: record,
    )
  end

  it "continues a terminal session with an explicit task" do
    control.start(prompt: "First", record:, run_id: "turn-1")
    session.append(:terminal, { outcome: :failed }, key: "terminal:turn-1", run_id: "turn-1")

    control.continue(prompt: "Try another way", run_id: "turn-2")

    expect(session.entries.last(2)).to match(
      [
        have_attributes(kind: "run_record", run_id: "turn-2"),
        have_attributes(
          kind: "user",
          run_id: "turn-2",
          payload: {
            "content" => [{ "type" => "text", "text" => "Try another way" }],
          },
        ),
      ],
    )
  end

  it "writes one stop request for the pending turn" do
    control.start(prompt: "First", record:, run_id: "turn-1")

    expect(control.stop).to eq("turn-1")
    expect(control.stop).to eq("turn-1")
    expect(session.entries.count { |entry| entry.kind == "stop_request" }).to eq(1)
  end

  it "fails a turn once and returns its tagged event" do
    error = RuntimeError.new("invalid record")

    event = control.fail_run(run_id: "turn-1", reason: :invalid_run_record, error:)

    expect(event).to have_attributes(
      type: :"run.failed",
      session_id: "session-1",
      run_id: "turn-1",
      reason: :invalid_run_record,
      error: "invalid record",
    )
    expect(session.entries.last).to have_attributes(
      kind: "terminal",
      key: "terminal:turn-1",
      run_id: "turn-1",
      payload: {
        "outcome" => "failed",
        "reason" => "invalid_run_record",
        "error" => "invalid record",
      },
    )
    expect(control.fail_run(run_id: "turn-1", reason: :exception, error:)).to be_nil
    expect(session.entries.count { |entry| entry.kind == "terminal" }).to eq(1)
  end
end
