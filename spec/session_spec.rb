# frozen_string_literal: true

RSpec.describe AimHelm::Session do
  around do |example|
    Dir.mktmpdir("aim_helm-session") do |dir|
      @store = AimHelm::Stores::JSONL.new(dir:)
      example.run
    end
  end

  subject(:session) { described_class.new(store: @store, id: SecureRandom.uuid_v7) }

  it "mints a UUIDv7 when no id is supplied" do
    generated = described_class.new(store: @store)

    expect(generated.id.split("-").fetch(2)).to start_with("7")
  end

  it "derives lifecycle status from the ordered log" do
    run_id = "run-1"
    turn_id = "turn-1"
    expect(session.status).to eq(:empty)

    session.append(:user, { content: [] }, run_id:)
    expect(session.status).to eq(:queued)

    session.append(:assistant, { content: [] }, run_id:, turn_id:)
    expect(session.status).to eq(:running)

    session.append(:approval_request, { call_id: "call-1" }, run_id:, turn_id:)
    session.append(:approval_request, { call_id: "call-2" }, run_id:, turn_id:)
    expect(session.status).to eq(:awaiting_approval)

    session.append(
      :approval_decision,
      { call_id: "call-1", verdict: "approve" },
      run_id:,
      turn_id:,
    )
    expect(session.status).to eq(:awaiting_approval)

    session.append(
      :approval_decision,
      { call_id: "call-2", verdict: "approve" },
      run_id:,
      turn_id:,
    )
    expect(session.status).to eq(:queued)

    session.append(:terminal, { outcome: "done" }, key: "terminal", run_id:)
    expect(session.status).to eq(:completed)

    session.append(:usage, { purpose: :compaction }, run_id:)
    session.append(:compaction, { summary: "Earlier work", covers_through_entry_id: 1 }, run_id:)
    expect(session.status).to eq(:completed)

    control = AimHelm::Control.new(session:)
    control.queue_message(content: "follow-up", type: :report, key: "report:1")
    expect(session.status).to eq(:completed)
  end

  it "returns the oldest user turn without a terminal" do
    session.append(:run_record, {}, run_id: "run-1")
    session.append(:user, { content: [] }, run_id: "run-1")
    session.append(:run_record, {}, run_id: "run-2")
    session.append(:user, { content: [] }, run_id: "run-2")

    expect(session.pending_run_id).to eq("run-1")

    session.append(:terminal, { outcome: "done" }, run_id: "run-1")

    expect(session.pending_run_id).to eq("run-2")

    session.append(:terminal, { outcome: "failed" }, run_id: "run-2")

    expect(session.pending_run_id).to be_nil
  end

  it "keeps the first durable decision across duplicate submissions" do
    run_id = "run-1"
    turn_id = "turn-1"
    tool_call = { id: "call-1", name: "lookup", arguments: {} }
    approval = {
      call_id: "call-1",
      name: "lookup",
      tool_name: "reports/lookup",
      arguments: {},
      title: "lookup",
    }
    session.append(:user, { content: [] }, run_id:)
    session.append(:tool_call, tool_call, key: "call:call-1", run_id:, turn_id:)
    session.append(
      :approval_request,
      approval,
      key: "approval:call-1",
      run_id:,
      turn_id:,
    )

    first = AimHelm::Control.new(session:).decide(
      call_id: "call-1",
      verdict: :approve,
      decided_by: "user-1",
      rule: "rule-1",
    )
    duplicate = AimHelm::Control.new(session:).decide(
      call_id: "call-1",
      verdict: :approve,
      decided_by: "user-1",
      rule: "rule-1",
    )

    expect(first).to be_a(AimHelm::Session::Record)
    expect(duplicate).to be_nil
    expect(session.entries.count { |entry| entry.kind == "approval_decision" }).to eq(1)
    expect do
      AimHelm::Control.new(session:).decide(call_id: "call-1", verdict: :deny,
                                            decided_by: "user-1")
    end.to raise_error(AimHelm::ConfigurationError, /already been decided/)
  end

  it "broadcasts each newly committed human decision once" do
    deliveries = []
    dispatches = []
    configured = session.new(
      config: AimHelm.config.with(
        broadcast: deliveries.method(:<<),
        advance: dispatches.method(:<<),
      ),
    )
    run_id = "run-1"
    turn_id = "turn-1"
    configured.append(:user, { content: [] }, run_id:)

    %w[approved denied].each do |suffix|
      call_id = "call-#{suffix}"
      configured.append(
        :tool_call,
        { id: call_id, name: "publish", arguments: { value: suffix } },
        key: "call:#{call_id}",
        run_id:,
        turn_id:,
      )
      configured.append(
        :approval_request,
        {
          call_id:,
          name: "publish",
          tool_name: "reports/publish",
          arguments: { value: suffix },
          title: "Publish #{suffix}",
        },
        key: "approval:#{call_id}",
        run_id:,
        turn_id:,
      )
    end

    decision = configured.approve("call-approved", by: "user-1")
    duplicate = configured.approve("call-approved", by: "user-1")
    configured.deny("call-denied", by: "user-1", reason: "Not ready")

    expect(decision).to be_a(AimHelm::Session::Record)
    expect(duplicate).to be_nil
    expect(dispatches).to eq([configured.id, configured.id])
    expect(deliveries.map { |delivery| delivery.event.type })
      .to eq(%i[tool.approved tool.denied])
    expect(deliveries.map(&:session)).to all(eq(configured))
    expect(deliveries.map(&:context)).to all(be_nil)
    expect(deliveries.map(&:event)).to contain_exactly(
      have_attributes(
        type: :"tool.approved",
        session_id: configured.id,
        run_id:,
        turn_id:,
        call_id: "call-approved",
        name: "publish",
        arguments: { "value" => "approved" },
        title: "Publish approved",
      ),
      have_attributes(
        type: :"tool.denied",
        session_id: configured.id,
        run_id:,
        turn_id:,
        call_id: "call-denied",
        name: "publish",
        arguments: { "value" => "denied" },
        title: "Publish denied",
      ),
    )
  end

  it "folds all unconsumed queued messages into one user turn" do
    control = AimHelm::Control.new(session:)
    first = control.queue_message(content: "First instruction", key: "message:1")
    second = control.queue_message(
      content: "Child finished",
      type: :report,
      key: "report:1",
      subagent_session_id: "child-1",
    )

    folded = session.fold_messages(run_id: "turn-1")

    expect(folded).to have_attributes(kind: "user", run_id: "turn-1")
    expect(folded.payload).to eq(
      "content" => [
        { "type" => "text", "text" => "First instruction\n\nChild finished" },
      ],
      "covers_through_entry_id" => second.id,
    )
    expect(session.pending_messages).to be_empty
    expect(first.id).to be < second.id

    control.queue_message(content: "Next instruction", key: "message:2")

    expect(session.pending_messages.map(&:key)).to eq(["message:2"])
  end

  it "raises on a duplicate strict append" do
    session.append!(:user, { content: [] }, key: "user:1", run_id: "turn-1")

    expect do
      session.append!(:user, { content: [] }, key: "user:1", run_id: "turn-1")
    end.to raise_error(AimHelm::AppendAnomaly, /duplicate user/)
  end
end
