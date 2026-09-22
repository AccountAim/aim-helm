# frozen_string_literal: true

RSpec.describe AimHelm::Subagents::ReportRecovery do
  around do |example|
    Dir.mktmpdir("aim_helm-report-recovery") do |dir|
      @store = AimHelm::Stores::JSONL.new(dir:)
      example.run
    end
  end

  let(:dispatches) { [] }
  let(:config) { AimHelm.config.with(advance: dispatches.method(:<<)) }
  let(:parent) { AimHelm::Session.new(store: @store, id: "parent-1", config:) }
  let(:session) { AimHelm::Session.new(store: @store, id: "child-1", config:) }
  let(:record) do
    AimHelm::Subagents::Record.new(
      session_id: session.id,
      parent_session_id: parent.id,
      run_id: "child-turn-1",
      parent_run_id: "parent-turn-1",
      call_id: "call-1",
      name: "researcher",
      task: "Research",
      mode:,
      options: run_record,
    )
  end
  let(:mode) { :background }
  let(:run_record) { AimHelm::Agent::Record.new(system: "Research.", model: "gpt-6-luna") }

  before do
    AimHelm::Control.new(session: parent).start(
      prompt: "Coordinate",
      record: run_record,
      run_id: "parent-turn-1",
    )
    parent.append(
      :tool_call,
      { "id" => "call-1", "name" => "spawn_agent", "arguments" => { "agent" => "researcher" } },
      key: "call:call-1",
      run_id: "parent-turn-1",
      turn_id: "parent-turn-1",
    )
    parent.append(
      :subagent,
      { "id" => session.id, "name" => "researcher", "mode" => mode.to_s, "call_id" => "call-1" },
      key: "subagent:#{session.id}",
      run_id: "parent-turn-1",
      turn_id: "parent-turn-1",
    )
    AimHelm::Control.new(session:).start_subagent(record:)
    session.append(
      :assistant,
      {
        content: "Research complete",
        model: "gpt-6-luna",
        provider: :openai,
        stop_reason: :stop,
      },
      run_id: record.run_id,
    )
    session.append(
      :terminal,
      { outcome: :done },
      key: "terminal:#{record.run_id}",
      run_id: record.run_id,
    )
  end

  it "answers the parked spawn call once from the durable log" do
    2.times { described_class.new(session:, parent:).call }

    results = parent.entries.select { |entry| entry.key == "result:call-1" }
    expect(results.one?).to be(true)
    expect(results.fetch(0).payload).to include("call_id" => "call-1")
    expect(results.fetch(0).payload["output"]).to include("researcher", "Research complete")
    expect(dispatches).to eq(["parent-1"])
  end

  it "leaves a delegated call open when the parent is advanced before its child reports" do
    entries = parent.entries
    delegated = AimHelm::Subagents::Record.delegated_call_ids(entries)

    expect(delegated).to contain_exactly("call-1")
    expect(AimHelm::Session.status_from(entries)).to eq(:awaiting_subagent)
  end

  context "with an inline subagent" do
    let(:mode) { :inline }

    it "does not deliver its report" do
      described_class.new(session:, parent:).call

      expect(parent.entries.none? { |entry| entry.kind == "queued_message" }).to be(true)
    end
  end
end
