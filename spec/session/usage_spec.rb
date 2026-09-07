# frozen_string_literal: true

RSpec.describe AimHelm::Session::Usage do
  around do |example|
    Dir.mktmpdir("aim_helm-usage") do |dir|
      @store = AimHelm::Stores::JSONL.new(dir:)
      example.run
    end
  end

  let(:session) { AimHelm::Session.new(store: @store, id: "session-1") }

  def append_assistant(target, model: "gpt-5.6-luna", **usage)
    counts = { input_tokens: 100, output_tokens: 20, cached_input_tokens: 0,
               cache_write_tokens: 0, reasoning_tokens: 0, cost: 0.001,
               wall_clock: 1.5 }.merge(usage)
    target.append(
      :assistant,
      { content: [{ type: "text", text: "ok" }], model:, usage: counts.merge(model:) },
      run_id: "run-1",
    )
  end

  def append_compaction(target, model: "gpt-5.6-luna", **usage)
    counts = { input_tokens: 500, output_tokens: 60, cached_input_tokens: 0,
               cache_write_tokens: 0, reasoning_tokens: 0, cost: 0.004,
               wall_clock: 0.5 }.merge(usage)
    target.append(:usage, counts.merge(model:, purpose: "compaction"), run_id: "run-1")
  end

  def spawn(child_id, name:)
    session.append(:subagent, { "id" => child_id, "name" => name }, run_id: "run-1")
    AimHelm::Session.new(store: @store, id: child_id)
  end

  it "reports one step per provider call, numbered oldest first" do
    append_assistant(session)
    append_assistant(session, input_tokens: 300, cached_input_tokens: 90, cost: 0.002)

    steps = session.usage.steps
    expect(steps.map(&:sequence)).to eq([1, 2])
    expect(steps.first).to have_attributes(model: "gpt-5.6-luna", input: 100, cost: 0.001,
                                           agent: nil)
    expect(steps.last).to have_attributes(input: 300, cached: 90, cost: 0.002)
  end

  it "counts cache writes as cached tokens" do
    append_assistant(session, cached_input_tokens: 40, cache_write_tokens: 60)

    expect(session.usage.steps.first.cached).to eq(100)
  end

  it "skips turns the provider reported no usage for" do
    session.append(:assistant, { content: [{ type: "text", text: "none" }], model: "m" },
                   run_id: "run-1")

    expect(session.usage.steps).to be_empty
    expect(session.usage.total).to have_attributes(calls: 0, cost: 0)
  end

  it "folds compaction into per-model rows and the total" do
    append_assistant(session)
    append_compaction(session)

    usage = session.usage
    expect(usage.by_model.first).to have_attributes(model: "gpt-5.6-luna", calls: 2, input: 600,
                                                    output: 80, cost: 0.005)
    expect(usage.total).to have_attributes(calls: 2, cost: 0.005)
    expect(usage.steps.last.purpose).to eq("compaction")
  end

  it "groups a run that switched models" do
    append_assistant(session, model: "gpt-5.6-luna")
    append_assistant(session, model: "gpt-5.6-terra", input_tokens: 200, cost: 0.002)

    rows = session.usage.by_model
    expect(rows.map(&:model)).to eq(%w[gpt-5.6-luna gpt-5.6-terra])
    expect(rows.last).to have_attributes(calls: 1, input: 200)
  end

  it "walks subagents through their spawn markers and attributes their calls" do
    append_assistant(session)
    child = spawn("session-2", name: "researcher")
    append_assistant(child, model: "claude-haiku-4-5", input_tokens: 400, cost: 0.003)

    usage = session.usage
    expect(usage.steps.map(&:agent)).to eq([nil, "researcher"])
    expect(usage.total).to have_attributes(calls: 2, input: 500, cost: 0.004)
    expect(usage.by_model.map(&:model)).to contain_exactly("gpt-5.6-luna", "claude-haiku-4-5")
  end

  it "keeps the deepest agent's name when subagents nest" do
    child = spawn("session-2", name: "researcher")
    child.append(:subagent, { "id" => "session-3", "name" => "analyst" }, run_id: "run-1")
    append_assistant(AimHelm::Session.new(store: @store, id: "session-3"))

    expect(session.usage.steps.map(&:agent)).to eq(["analyst"])
  end

  it "reports the newest step as the last turn" do
    append_assistant(session)
    append_assistant(session, input_tokens: 700, cost: 0.005)

    expect(session.usage.last_turn).to have_attributes(input: 700, cost: 0.005)
  end

  it "renders a transcript row for a durable entry" do
    append_assistant(session)
    entry = session.entries.first

    expect(described_class::Step.history_item(entry)).to include(type: "usage", input: 100)
  end
end
