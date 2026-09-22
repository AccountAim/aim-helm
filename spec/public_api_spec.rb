# frozen_string_literal: true

RSpec.describe "AimHelm public API" do
  it "loads without resolving optional Rails integration constants" do
    expect(Object.const_defined?(:Rails, false)).to be(false)
    expect(AimHelm.const_defined?(:ActiveJob, false)).to be(false)
    expect(AimHelm::Stores.const_defined?(:ActiveRecord, false)).to be(false)
  end

  it "builds an immutable runnable agent with application-facing names" do
    agent = AimHelm.agent(
      "gpt-6-luna",
      instructions: "Answer accurately.",
      max_turns: 8,
    )
    careful = agent.with(reasoning: :high)

    expect(agent).to have_attributes(
      model: "gpt-6-luna",
      instructions: "Answer accurately.",
      max_turns: 8,
      reasoning: nil,
    )
    expect(careful).to have_attributes(reasoning: :high, instructions: agent.instructions)
    expect(agent).not_to respond_to(:close)
    expect(agent).not_to respond_to(:system)
    expect(agent).not_to respond_to(:max_iterations)
    expect(agent).not_to respond_to(:output_schema)
    expect do
      AimHelm::Agent.new(model: "gpt-6-luna", system: "Legacy spelling")
    end.to raise_error(Dry::Struct::Error)
  end

  it "runs without an explicit store or session and returns a completed run" do
    provider = AimHelm::Providers::Fake.new(turns: [{ text: "Hello" }])
    agent = AimHelm.agent("gpt-6-luna", instructions: "Be brief.", provider:)

    run = agent.run!("Say hello")

    expect(run).to be_a(AimHelm::Run::Completed)
    expect(run).to have_attributes(text: "Hello", status: :completed)
    expect(run.session).to be_a(AimHelm::Session)
    expect(run.session.status).to eq(:completed)
  end

  it "continues the in-memory session carried by a run" do
    provider = AimHelm::Providers::Fake.new(turns: [{ text: "Stored" }, { text: "cedar-17" }])
    agent = AimHelm.agent("gpt-6-luna", provider:)

    first = agent.run("Remember cedar-17")
    second = agent.run("What was it?", session: first.session)

    expect(second).to be_a(AimHelm::Run::Completed)
    expect(second.text).to eq("cedar-17")
    expect(second.session).to eq(first.session)
  end

  it "parks for approval, decides through the session, and continues with run" do
    provider = AimHelm::Providers::Fake.new(
      turns: [
        { tool_calls: [{ id: "call-1", name: "publish", arguments: {} }] },
        { text: "Published" },
      ],
    )
    publish = AimHelm::Tool.define(
      "publish",
      "Publishes text",
      needs_approval: true,
    ) { "ok" }
    agent = AimHelm.agent("gpt-6-luna", tools: [publish], provider:)

    parked = agent.run("Publish ready")
    parked.session.approve("call-1", by: "user:42", note: "Reviewed")
    completed = agent.run(session: parked.session)

    expect(parked).to be_a(AimHelm::Run::AwaitingApproval)
    expect(parked.pending_approvals.map(&:call_id)).to eq(["call-1"])
    expect(completed).to be_a(AimHelm::Run::Completed)
    expect(completed.text).to eq("Published")
  end

  it "raises IncompleteRun from the bang form with the typed outcome attached" do
    provider = AimHelm::Providers::Fake.new(
      turns: [{ tool_calls: [{ id: "call-1", name: "publish", arguments: {} }] }],
    )
    publish = AimHelm::Tool.define("publish", "Publishes", needs_approval: true) { "ok" }
    agent = AimHelm.agent("gpt-6-luna", tools: [publish], provider:)

    expect { agent.run!("Publish") }.to raise_error(AimHelm::IncompleteRun) do |error|
      expect(error.run).to be_a(AimHelm::Run::AwaitingApproval)
    end
  end

  it "accepts and dispatches work without exposing a turn id to the caller" do
    dispatched = []
    provider = AimHelm::Providers::Fake.new(turns: [{ text: "Done" }])
    config = AimHelm.config.with(
      advance: ->(session_id) { dispatched << session_id },
      provider_factory: ->(*) { provider },
    )
    session = AimHelm::Session.new(store: AimHelm::Stores::Memory.new, config:)
    agent = AimHelm.agent("gpt-6-luna", instructions: "Be brief.")

    queued = agent.run("Do it", session:)
    completed = AimHelm.agent(session:).advance

    expect(queued).to be_a(AimHelm::Run::Queued)
    expect(dispatched).to eq([session.id])
    expect(completed).to be_a(AimHelm::Run::Completed)
    expect(completed.text).to eq("Done")
  end

  it "takes the session keyword when advancing an explicit definition" do
    provider = AimHelm::Providers::Fake.new(turns: [{ text: "Done" }])
    session = AimHelm::Session.new(store: AimHelm::Stores::Memory.new)
    agent = AimHelm.agent("gpt-6-luna", provider:)
    AimHelm::Control.new(session:).start(
      prompt: "Do it",
      record: AimHelm::Agent::Record.capture(options: agent),
    )

    run = agent.advance(session:)

    expect(run).to have_attributes(status: :completed, text: "Done")
    expect { agent.advance(session) }.to raise_error(ArgumentError)
  end

  it "can execute inline despite a configured dispatcher" do
    dispatched = []
    provider = AimHelm::Providers::Fake.new(turns: [{ text: "Done here" }])
    config = AimHelm.config.with(advance: ->(session_id) { dispatched << session_id })
    session = AimHelm::Session.new(store: AimHelm::Stores::Memory.new, config:)
    agent = AimHelm.agent("gpt-6-luna", advance: :inline, provider:)

    run = agent.run("Do it here", session:)

    expect(run).to be_a(AimHelm::Run::Completed)
    expect(run.text).to eq("Done here")
    expect(dispatched).to be_empty
  end

  it "uses run for follow-up input while durable work is already queued" do
    dispatched = []
    config = AimHelm.config.with(advance: ->(session_id) { dispatched << session_id })
    session = AimHelm::Session.new(store: AimHelm::Stores::Memory.new, config:)
    agent = AimHelm.agent("gpt-6-luna")

    first = agent.run("Start", session:)
    second = agent.run("Use the revised report", session:)

    expect(first).to be_a(AimHelm::Run::Queued)
    expect(second).to be_a(AimHelm::Run::Queued)
    expect(session.pending_message_content).to eq(
      [{ "type" => "text", "text" => "Use the revised report" }],
    )
    expect(dispatched).to eq([session.id, session.id])
  end

  it "keeps a queued outcome identifiable if the live runner finishes during dispatch" do
    provider = AimHelm::Providers::Fake.new(turns: [{ text: "Done" }])
    agent = AimHelm.agent("gpt-6-luna", provider:)
    session = nil
    advance = ->(*) { agent.advance(session:) }
    session = AimHelm::Session.new(
      store: AimHelm::Stores::Memory.new,
      config: AimHelm.config.with(advance:),
    )
    run_id = AimHelm::Control.new(session:).start(
      prompt: "Start",
      record: AimHelm::Agent::Record.capture(options: agent),
    )

    queued = agent.run("Use the revised report", session:)

    expect(queued).to have_attributes(id: run_id, status: :queued)
    expect(session.status).to eq(:completed)
  end

  it "parses, repairs, and validates structured output" do
    schema = AimHelm::Schema.define do
      required(:answer).filled(:string)
    end
    provider = AimHelm::Providers::Fake.new(
      turns: [
        { text: "not json" },
        { text: JSON.generate(answer: "cedar-17") },
      ],
    )
    agent = AimHelm.agent(
      "gpt-6-luna",
      output_retries: 1,
      provider:,
    )

    run = agent.run("Return the codeword", output: schema)

    expect(run).to be_a(AimHelm::Run::Completed)
    expect(run.output).to eq(answer: "cedar-17")
    expect(provider.requests.length).to eq(2)
  end

  it "returns a typed invalid-output failure after repair is exhausted" do
    schema = AimHelm::Schema.define do
      required(:answer).filled(:string)
    end
    provider = AimHelm::Providers::Fake.new(turns: [{ text: "not json" }])
    agent = AimHelm.agent("gpt-6-luna", output_retries: 0, provider:)

    run = agent.run("Return JSON", output: schema)

    expect(run).to be_a(AimHelm::Run::Failed)
    expect(run.reason).to eq(:invalid_output)
    expect(run.session.status).to eq(:failed)
  end

  it "serializes provider and concurrent tool events through one callback owner" do
    provider = AimHelm::Providers::Fake.new(
      turns: [
        {
          tool_calls: [
            { id: "call-1", name: "first", arguments: {} },
            { id: "call-2", name: "second", arguments: {} },
          ],
        },
        { text: "Done" },
      ],
    )
    first = AimHelm::Tool.define("first", description: "First") { "first" }
    second = AimHelm::Tool.define("second", description: "Second") { "second" }
    owners = Queue.new
    agent = AimHelm.agent("gpt-6-luna", tools: [first, second], provider:)

    agent.run("Use both tools") { owners << Thread.current.object_id }
    owner_ids = []
    owner_ids << owners.pop until owners.empty?

    expect(owner_ids.uniq.length).to eq(1)
  end

  it "composes foreground event streaming with the configured process broadcast" do
    previous_broadcast = AimHelm.config.broadcast
    foreground = []
    deliveries = []
    context = Object.new
    AimHelm.configure { |config| config.broadcast = ->(delivery) { deliveries << delivery } }
    agent = AimHelm.agent(
      "gpt-6-luna",
      provider: AimHelm::Providers::Fake.new(turns: [{ text: "Done" }]),
    )

    run = agent.run("Do it", context:) { |event| foreground << event }

    expect(foreground.map(&:type)).to eq(deliveries.map { |delivery| delivery.event.type })
    expect(deliveries).not_to be_empty
    expect(deliveries).to all(
      have_attributes(session: run.session, context:),
    )
  ensure
    AimHelm.configure { |config| config.broadcast = previous_broadcast }
  end

  it "exposes application context while broadcasting tool events with correlation context" do
    previous_broadcast = AimHelm.config.broadcast
    foreground = []
    deliveries = []
    app = Object.new
    tool_context = nil
    tool = AimHelm::Tool.define("lookup",
                                description: "Looks up a report") do |_arguments, context|
      tool_context = context
      context.broadcast(:"report.loaded", report_id: "report-1")
      "ready"
    end
    provider = AimHelm::Providers::Fake.new(
      turns: [
        { tool_calls: [{ id: "call-1", name: "lookup", arguments: {} }] },
        { text: "Done" },
      ],
    )
    AimHelm.configure { |config| config.broadcast = ->(delivery) { deliveries << delivery } }
    agent = AimHelm.agent("gpt-6-luna", tools: [tool], provider:)

    run = agent.run("Load the report", context: app) { |event| foreground << event }
    event = foreground.find { |candidate| candidate.type == :"report.loaded" }
    delivery = deliveries.find { |candidate| candidate.event.equal?(event) }
    tool_call = run.session.entries.find { |entry| entry.kind == "tool_call" }

    expect(event).to have_attributes(
      session_id: run.session.id,
      run_id: run.id,
      turn_id: tool_call.turn_id,
      call_id: "call-1",
      payload: { "report_id" => "report-1" },
    )
    expect(tool_context).to have_attributes(
      app:,
      session_id: run.session.id,
      run_id: run.id,
      turn_id: tool_call.turn_id,
    )
    expect(delivery).to have_attributes(event:, session: run.session, context: app)
  ensure
    AimHelm.configure { |config| config.broadcast = previous_broadcast }
  end

  it "sends declared tool failures to the model and retains host metadata" do
    provider = AimHelm::Providers::Fake.new(
      turns: [
        { tool_calls: [{ id: "call-1", name: "lookup", arguments: {} }] },
        { text: "The report is unavailable." },
      ],
    )
    lookup = AimHelm::Tool.define("lookup", description: "Looks up a report") do
      AimHelm::Tool::Result.failure(
        content: "Report is missing",
        metadata: { report_id: "report-1" },
      )
    end
    agent = AimHelm.agent("gpt-6-luna", tools: [lookup], provider:)

    run = agent.run("Find the report")
    tool_result = run.session.entries.find { |entry| entry.kind == "tool_result" }

    expect(run.text).to eq("The report is unavailable.")
    expect(tool_result.payload).to include(
      "error" => true,
      "metadata" => { "report_id" => "report-1" },
    )
  end

  it "durably fails and re-raises unexpected tool exceptions" do
    provider = AimHelm::Providers::Fake.new(
      turns: [{ tool_calls: [{ id: "call-1", name: "lookup", arguments: {} }] }],
    )
    lookup = AimHelm::Tool.define("lookup", description: "Looks up a report") do
      raise IOError, "database unavailable"
    end
    session = AimHelm::Session.new(store: AimHelm::Stores::Memory.new)
    agent = AimHelm.agent("gpt-6-luna", tools: [lookup], provider:)

    expect { agent.run("Find the report", session:) }
      .to raise_error(IOError, "database unavailable")
    expect(session.status).to eq(:failed)
  end

  it "opens a session through the configured default store" do
    store = AimHelm::Stores::Memory.new
    previous_store = AimHelm.config.store
    AimHelm.configure { |config| config.store = store }

    session = AimHelm.session("session-1")

    expect(session).to have_attributes(id: "session-1", status: :empty)
  ensure
    AimHelm.configure { |config| config.store = previous_store }
  end

  it "does not silently open unknown ids against a process-global memory store" do
    previous_store = AimHelm.config.store
    AimHelm.configure { |config| config.store = nil }
    run = AimHelm.agent(
      "gpt-6-luna",
      provider: AimHelm::Providers::Fake.new(turns: [{ text: "Done" }]),
    ).run("Do it")

    expect { AimHelm.session(run.session.id) }
      .to raise_error(AimHelm::ConfigurationError, /no default session store/)
  ensure
    AimHelm.configure { |config| config.store = previous_store }
  end

  it "does not expose the old module run function" do
    expect(AimHelm).not_to respond_to(:run)
    expect(AimHelm).not_to respond_to(:reconstruct_agent)
  end
end
