# frozen_string_literal: true

RSpec.describe AimHelm::Providers::Fake do
  around do |example|
    provider_factory = AimHelm.config.provider_factory
    Dir.mktmpdir("aim_helm-fake") do |dir|
      @session = AimHelm::Session.new(store: AimHelm::Stores::JSONL.new(dir:))
      example.run
    end
  ensure
    AimHelm.configure { |config| config.provider_factory = provider_factory }
  end

  it "drives a complete tool conversation through the real runner" do
    provider = described_class.new(
      turns: [
        { tool_calls: [{ name: "lookup", arguments: { report_id: "1" } }] },
        { text: "Report ready" },
      ],
      chunk_size: 5,
    )
    tool = AimHelm::Tool.define("lookup", "Looks up a report") { "found" }
    options = AimHelm::Agent.new(
      instructions: "Answer accurately.",
      model: "gpt-6-luna",
      tools: [tool],
    )
    events = []

    result = options.with(provider:).run(
      "Find the report",
      session: @session,
      &events.method(:<<)
    )

    expect(result.text).to eq("Report ready")
    expect(provider.requests.length).to eq(2)
    expect(@session.entries.map(&:kind)).to include("tool_call", "tool_result", "terminal")
    partial = events.select { |event| event.type == :"tool.delta" }.last
    expect(partial.arguments).to eq("report_id" => "1")
  end

  it "records the request and raises a scripted provider error" do
    provider = described_class.new(turns: [{ error: "offline" }])

    expect do
      provider.stream(messages: [AimHelm::Message.user("Try")])
    end.to raise_error(AimHelm::ProviderError, "offline")
    expect(provider.requests.first.fetch(:messages).first.text).to eq("Try")
  end

  it "scripts transient errors independently from later turns" do
    provider = described_class.new(
      turns: [
        { error: "retry", transient: true },
        { text: "Recovered" },
      ],
    )

    expect { provider.stream }.to raise_error(AimHelm::TransientError, "retry")
    expect(provider.stream.text).to eq("Recovered")
    expect(provider.requests.count).to eq(2)
  end

  it "drives an ordinary run through the configured provider factory" do
    AimHelm.configure do |config|
      config.provider_factory = lambda do |model, **|
        described_class.new(model:, turns: [{ text: "Factory response" }])
      end
    end
    options = AimHelm::Agent.new(instructions: "Answer.", model: "gpt-6-luna")

    session = @session.new(config: AimHelm.config)
    result = options.run("Hello", session:)

    expect(result.text).to eq("Factory response")
  end

  it "resumes the oldest pending turn without caller bookkeeping" do
    provider = described_class.new(turns: [{ text: "Resumed" }])
    options = default_options
    run_id = AimHelm::Control.new(session: @session).start(
      prompt: "Continue this",
      record: AimHelm::Agent::Record.capture(options:),
    )

    result = options.with(provider:).advance(session: @session)

    expect(result).to have_attributes(text: "Resumed", id: run_id)
    expect(@session.entries.count { |entry| entry.kind == "user" }).to eq(1)
  end

  it "queues a second prompt while a turn is pending" do
    options = default_options
    session = @session.new(config: @session.config.with(advance: ->(*) {}))
    AimHelm::Control.new(session:).start(
      prompt: "First",
      record: AimHelm::Agent::Record.capture(options:),
    )

    result = options.run("Second", session:)

    expect(result).to be_a(AimHelm::Run::Queued)
    expect(session.pending_messages.length).to eq(1)
  end

  it "continues a terminal session with a fresh run definition" do
    provider = described_class.new(turns: [{ text: "First" }, { text: "Second" }])
    initial = default_options
    revised = initial.new(instructions: "Use the revised instructions.")
    initial.with(provider:).run("Start", session: @session)

    result = revised.with(provider:).run("Continue", session: @session)

    records = @session.entries.select { |entry| entry.kind == "run_record" }
    expect(result.text).to eq("Second")
    expect(records.map { |entry| entry.payload.fetch("system") }).to eq(
      [initial.instructions, revised.instructions],
    )
  end

  it "continues a subagent through the public run facade" do
    provider = described_class.new(turns: [{ text: "First" }, { text: "Second" }])
    initial = default_options
    revised = initial.new(instructions: "Use the revised instructions.")
    spawn = AimHelm::Subagents::Record.new(
      session_id: @session.id,
      parent_session_id: "parent-1",
      run_id: "turn-1",
      parent_run_id: "parent-turn-1",
      call_id: "call-1",
      name: "researcher",
      task: "Start",
      mode: :background,
      options: AimHelm::Agent::Record.capture(options: initial),
    )
    AimHelm::Control.new(session: @session).start_subagent(record: spawn)
    initial.with(provider:).advance(session: @session)

    revised.with(provider:).run("Continue", session: @session)

    continued = AimHelm::Subagents::Record.latest(@session.entries)
    expect(continued).to have_attributes(
      run_id: @session.entries.last.run_id,
      task: "Continue",
      options: AimHelm::Agent::Record.capture(options: revised),
    )
  end

  it "folds queued messages into a continuation turn" do
    provider = described_class.new(turns: [{ text: "First" }, { text: "Followed up" }])
    options = default_options
    options.with(provider:).run("Start", session: @session)
    AimHelm::Control.new(session: @session).queue_message(content: "Use the new report")

    result = options.with(provider:).run(session: @session)

    expect(result.text).to eq("Followed up")
    expect(@session.pending_messages).to be_empty
    expect(provider.requests.last.fetch(:messages).last.text).to eq("Use the new report")
  end

  it "rejects a run without a prompt or durable work" do
    expect do
      default_options.run(session: @session)
    end.to raise_error(AimHelm::ConfigurationError, /no pending run or queued messages/)
  end

  def default_options
    AimHelm::Agent.new(instructions: "Answer.", model: "gpt-6-luna")
  end
end
