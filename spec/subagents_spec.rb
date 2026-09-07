# frozen_string_literal: true

RSpec.describe "AimHelm subagents" do
  let(:session) do
    store = Class.new do
      def append(*) = nil
      def entries(*) = []
      def transaction(&block) = block.call
    end.new
    AimHelm::Session.new(store:, id: "parent-1")
  end
  let(:context) do
    AimHelm::Tools::Context.new(
      session:,
      events: ->(_event) {},
      app: Object.new,
      run_id: "parent-run-1",
      turn_id: "parent-turn-1",
      call_id: "call-1",
    )
  end

  it "wraps an ordinary agent in a narrow dispatch grant" do
    agent = AimHelm.agent(
      "gpt-5.6-luna",
      name: "researcher",
      description: "Researches one question",
      instructions: "Research carefully.",
      tools: [lookup],
    )

    grant = AimHelm::Subagent.new(agent:, modes: [:background])

    expect(grant).to have_attributes(
      name: "researcher",
      description: "Researches one question",
      system: "Research carefully.",
      tools: ["reports/lookup"],
      modes: [:background],
      definition: agent,
    )
  end

  it "opens a bounded dynamic-agent grant explicitly" do
    grant = AimHelm::Subagent.open(tools: [lookup], modes: [:background])

    expect(grant).to have_attributes(
      open: true,
      name: nil,
      tools: ["reports/lookup"],
      modes: [:background],
    )
  end

  it "derives child handles and reports from the parent and child logs" do
    store = AimHelm::Stores::Memory.new
    parent = AimHelm::Session.new(store:, id: "parent-1")
    child = AimHelm::Session.new(store:, id: "child-1")
    options = AimHelm::Agent::Record.new(system: "Research.", model: "gpt-5.6-luna")
    record = AimHelm::Subagents::Record.new(
      session_id: child.id,
      parent_session_id: parent.id,
      run_id: "child-run-1",
      parent_run_id: "parent-run-1",
      call_id: "call-1",
      name: "researcher",
      task: "Research",
      mode: :background,
      options:,
    )
    AimHelm::Control.new(session: child).start_subagent(record:)
    parent.append(:subagent, record.marker, run_id: "parent-run-1")
    child.append(
      :assistant,
      {
        content: [{ type: "text", text: "Ready" }],
        model: "gpt-5.6-luna",
        provider: :fake,
        stop_reason: :stop,
      },
      run_id: record.run_id,
    )
    child.append(:terminal, { outcome: :done }, run_id: record.run_id)

    handle = parent.subagents.fetch(0)

    expect(handle).to have_attributes(
      id: "child-1",
      name: "researcher",
      task: "Research",
      status: :completed,
    )
    expect(handle.report).to have_attributes(status: :completed, text: "Ready")
  end
  let(:lookup) do
    AimHelm::Tool.define(
      "lookup",
      "Looks up a report",
      identifier: "reports/lookup",
    ) { "ready" }
  end
  let(:definition) do
    AimHelm::Subagent.new(
      name: "researcher",
      description: "Researches one question",
      system: "Research carefully.",
      tools: ["reports/lookup"],
    )
  end
  let(:options) do
    AimHelm::Agent.new(
      instructions: "Coordinate the work.",
      model: "gpt-5.6-luna",
      tools: [lookup],
      subagents: [definition],
      reminders: [AimHelm::Reminder.new(text: "Stay focused.", every: 3)],
    )
  end

  it "materializes a named subagent grant before calling its host" do
    host = spawn_host
    tool = spawn_tool(options:, host:)

    result = tool.call(
      { "agent" => "researcher", "task" => "Find the latest report", "mode" => "background" },
      context:,
    )

    record = host.records.fetch(0)
    expect(result).to be(AimHelm::Tool::PARKED)
    expect(record).to have_attributes(
      parent_session_id: "parent-1",
      parent_run_id: "parent-run-1",
      call_id: "call-1",
      name: "researcher",
      task: "Find the latest report",
      mode: :background,
    )
    expect(record.options).to have_attributes(
      system: "Research carefully.",
      model: "gpt-5.6-luna",
      tools: ["reports/lookup"],
      subagents: nil,
      reminders: [have_attributes(text: "Stay focused.", every: 3)],
    )
  end

  it "advertises only fields accepted by named grants" do
    tool = spawn_tool(options:, host: spawn_host)

    expect(tool.input_schema.fetch("required")).to contain_exactly("agent", "task")
    expect(tool.input_schema.fetch("properties").keys).to contain_exactly(
      "agent",
      "mode",
      "task",
    )
    expect(tool.input_schema.dig("properties", "mode", "enum"))
      .to contain_exactly("inline", "background")
  end

  it "refuses gated tools inline and allows them in the background" do
    gated = AimHelm::Tool.define(
      "write",
      "Writes a report",
      identifier: "reports/write",
      needs_approval: true,
    ) { "written" }
    configured = options.new(
      tools: [gated],
      subagents: [AimHelm::Subagent.open(tools: [gated])],
    )
    host = spawn_host
    tool = spawn_tool(options: configured, host:)
    arguments = {
      "name" => "writer",
      "instructions" => "Write carefully.",
      "task" => "Write the report",
      "tools" => ["reports/write"],
    }

    expect { tool.call(arguments, context:) }
      .to raise_error(ArgumentError, /use background mode/)

    tool.call(arguments.merge("mode" => "background"), context:)

    expect(host.records.last.mode).to eq(:background)
  end

  it "requires a named agent when no open grant exists" do
    host = spawn_host
    tool = spawn_tool(options:, host:)
    arguments = {
      "name" => "analyst",
      "instructions" => "Analyze carefully.",
      "task" => "Analyze the report",
    }

    expect { tool.call(arguments, context:) }
      .to raise_error(ArgumentError, /agent.*is missing/)
  end

  it "keeps named specialists within their declared tool grant" do
    extra = AimHelm::Tool.define(
      "write",
      description: "Writes a report",
      identifier: "reports/write",
    ) { "written" }
    configured = options.new(tools: [lookup, extra])
    host = spawn_host
    tool = spawn_tool(options: configured, host:)

    tool.call(
      {
        "agent" => "researcher",
        "task" => "Research",
        "tools" => ["reports/write"],
      },
      context:,
    )

    expect(host.records.fetch(0).options.tools).to eq(["reports/lookup"])
  end

  it "rejects a specialist model outside the configured catalog" do
    specialist = definition.new(model: "private-model")
    configured = options.new(subagents: [specialist])

    expect { spawn_tool(options: configured, host: spawn_host) }
      .to raise_error(AimHelm::ConfigurationError, /private-model/)
  end

  it "gives each subagent an independently narrowed copy of the parent budget" do
    parent_budget = AimHelm::Budget.new(tokens: 100_000, cost: 2, wall_clock: 300)
    child = definition.new(budget: AimHelm::Budget.new(tokens: 20_000, cost: 3))
    configured = options.new(budget: parent_budget, subagents: [child])
    host = spawn_host
    tool = spawn_tool(options: configured, host:)

    tool.call(
      { "agent" => "researcher", "task" => "Find the report", "mode" => "background" },
      context:,
    )

    expect(host.records.fetch(0).options.budget).to have_attributes(
      tokens: 20_000,
      cost: 2.0,
      wall_clock: 300.0,
    )
  end

  it "forwards child controls and bounds model-selected wait time" do
    host = control_host
    tools = AimHelm::Tools::Agents::Control.new(host:).tools.to_h { |tool| [tool.name, tool] }

    expect(tools.fetch("list_agents").call({}, context:)).to eq([])

    result = tools.fetch("read_agent").call(
      { "id" => "child-1", "wait" => true, "timeout" => 300 },
      context:,
    )

    expect(result).to eq("status" => "completed")
    expect(host.calls.last).to eq(
      [
        :read,
        { id: "child-1", wait: true, timeout: 300, context: },
      ],
    )
    expect do
      tools.fetch("read_agent").call({ "id" => "child-1", "timeout" => 301 }, context:)
    end.to raise_error(ArgumentError, /timeout/)

    parked = tools.fetch("continue_agent").call(
      { "id" => "child-1", "task" => "Add one detail" },
      context:,
    )

    expect(parked).to be(AimHelm::Tool::PARKED)
  end

  it "round-trips and verifies a bounded spawn record" do
    host = spawn_host
    tool = spawn_tool(options:, host:)
    tool.call(
      { "agent" => "researcher", "task" => "Find the report", "mode" => "background" },
      context:,
    )
    record = host.records.fetch(0)

    restored = AimHelm::Subagents::Record.deserialize(record.dump)

    expect(restored.canonical).to eq(record.canonical)
    expect do
      AimHelm::Subagents::Record.deserialize(record.dump.merge("unexpected" => true))
    end.to raise_error(AimHelm::TamperedRecordError, /unexpected/)
  end

  def spawn_host
    Class.new do
      attr_reader :records

      def initialize = @records = []

      def spawn(record:, **)
        @records << record
        AimHelm::Subagents::Receipt.from(record)
      end
    end.new
  end

  def spawn_tool(options:, host:)
    models = ["gpt-5.6-luna"]
    spawner = AimHelm::Subagents::Spawner.new(options:, host:, models:)
    AimHelm::Tools::Agents::Spawn.new(options:, spawner:, models:).tools.fetch(0)
  end

  def control_host
    Class.new do
      attr_reader :calls

      def initialize = @calls = []

      def read(**arguments)
        @calls << [:read, arguments]
        { "status" => "completed" }
      end

      def queue_message(**arguments) = @calls << [:queue_message, arguments]
      def stop(**arguments) = @calls << [:stop, arguments]

      def continue(**arguments)
        @calls << [:continue, arguments]
        AimHelm::Subagents::Receipt.new(
          id: arguments.fetch(:id),
          name: "researcher",
          status: :queued,
        )
      end
    end.new
  end
end
