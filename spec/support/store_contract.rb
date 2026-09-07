# frozen_string_literal: true

RSpec.shared_examples "a AimHelm store" do
  let(:session_id) { SecureRandom.uuid_v7 }

  before { prepare_session.call(session_id) }

  it "appends typed entries in order with owned JSON payloads" do
    payload = { content: [{ type: "text", text: "before" }] }
    first = store.append(
      session_id,
      :user,
      payload,
      run_id: "run-1",
      turn_id: "turn-1",
    )
    payload.fetch(:content).first[:text] = "after"
    second = store.append(session_id, :assistant, { "content" => [] })

    entries = store.entries(session_id)
    expect(entries).to all(be_a(AimHelm::Session::Record))
    expect(entries.map(&:id)).to eq([first.id, second.id])
    expect(first.id).to be < second.id
    expect(entries.first.to_h).to include(
      session_id:,
      kind: "user",
      payload: { "content" => [{ "type" => "text", "text" => "before" }] },
      run_id: "run-1",
      turn_id: "turn-1",
    )
    expect(entries.first.created_at).to be_a(Time)
  end

  it "returns nil and preserves one entry for a duplicate key" do
    first = store.append(session_id, :tool_result, { "output" => "first" }, key: "result:1")
    duplicate = store.append(session_id, :tool_result, { "output" => "second" }, key: "result:1")

    expect(first).to be_a(AimHelm::Session::Record)
    expect(duplicate).to be_nil
    expect(store.entries(session_id).map(&:payload)).to eq([{ "output" => "first" }])
  end

  it "scopes idempotency keys to a session" do
    other_session_id = SecureRandom.uuid_v7
    prepare_session.call(other_session_id)

    expect(store.append(session_id, :terminal, { outcome: "done" }, key: "terminal"))
      .to be_a(AimHelm::Session::Record)
    expect(store.append(other_session_id, :terminal, { outcome: "done" }, key: "terminal"))
      .to be_a(AimHelm::Session::Record)
  end

  it "returns fresh payload objects on every read" do
    store.append(session_id, :user, { nested: { value: "original" } })
    store.entries(session_id).first.payload.fetch("nested")["value"] = "changed"

    expect(store.entries(session_id).first.payload).to eq(
      "nested" => { "value" => "original" },
    )
  end

  it "reads entries after an exclusive cursor" do
    first = store.append(session_id, :user, { content: "first" })
    second = store.append(session_id, :assistant, { content: "second" })
    third = store.append(session_id, :usage, { input_tokens: 1 })

    expect(store.entries(session_id, after_id: first.id).map(&:id)).to eq(
      [second.id, third.id],
    )
    expect(store.entries(session_id, after_id: third.id)).to be_empty
  end
end
