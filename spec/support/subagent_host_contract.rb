# frozen_string_literal: true

RSpec.shared_examples "a AimHelm subagent host" do
  it "continues an inline child synchronously under the new calling turn" do
    record = child_record.call(:inline)
    subagent_host.spawn(record:, context: parent_context)
    context = parent_context.new(call_id: "continue-1", run_id: "parent-run-2",
                                 turn_id: "parent-turn-2")

    output = subagent_host.continue(id: record.session_id, task: "Add one detail", context:)

    expect(output).to include("id" => record.session_id, "status" => "completed",
                              "text" => "Child complete")
    child = child_session.call(record.session_id)
    continued = AimHelm::Subagents::Record.latest(child.entries)
    expect(continued).to have_attributes(mode: :inline, parent_run_id: context.run_id,
                                         call_id: context.call_id)
    expect(child.entries.count { it.kind == "terminal" }).to eq(2)
    expect(parent_session.entries.last).to have_attributes(
      kind: "subagent", run_id: context.run_id, turn_id: context.turn_id,
      payload: hash_including("call_id" => context.call_id, "mode" => "inline")
    )
  end

  it "runs an inline child from its durable grant" do
    record = child_record.call(:inline)

    output = subagent_host.spawn(record:, context: parent_context)

    expect(output).to include(
      "id" => record.session_id,
      "name" => record.name,
      "status" => "completed",
      "text" => "Child complete",
    )
    expect(child_session.call(record.session_id).entries.map(&:kind)).to include(
      "spawn_record",
      "run_record",
      "user",
      "assistant",
      "terminal",
    )
    expect(parent_session.entries.last).to have_attributes(
      kind: "subagent",
      payload: hash_including("id" => record.session_id, "mode" => "inline"),
    )
  end

  it "runs a background child and delivers one durable report" do
    record = child_record.call(:background)

    receipt = subagent_host.spawn(record:, context: parent_context)
    finish_background.call(record)

    expect(receipt).to have_attributes(
      id: record.session_id,
      name: record.name,
      status: :queued,
    )
    expect(child_session.call(record.session_id).status).to eq(:completed)
    reports = parent_session.pending_messages.select do |entry|
      entry.payload["type"] == "report"
    end
    expect(reports.one?).to be(true)
    expect(reports.first.payload).to include(
      "subagent_session_id" => record.session_id,
      "subagent_name" => record.name,
      "subagent_status" => "completed",
    )
  end

  it "continues the same child identity after its terminal report" do
    record = child_record.call(:background)
    subagent_host.spawn(record:, context: parent_context)
    finish_background.call(record)

    receipt = subagent_host.continue(
      id: record.session_id,
      task: "Add one detail",
      context: parent_context,
    )

    child = child_session.call(record.session_id)
    expect(receipt).to have_attributes(
      id: record.session_id,
      status: :queued,
    )
    expect(child.entries.reverse_each.find { |entry| entry.kind == "user" }.payload).to include(
      "content" => [{ "type" => "text", "text" => "Add one detail" }],
    )
  end
end
