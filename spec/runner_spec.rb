# frozen_string_literal: true

RSpec.describe AimHelm::Runner do
  around do |example|
    Dir.mktmpdir("aim_helm-runner") do |dir|
      @store = AimHelm::Stores::JSONL.new(dir:)
      example.run
    end
  end

  let(:resolved_models) { [] }
  let(:config) do
    AimHelm.config.with(
      provider_factory: lambda do |model, **attributes|
        resolved_models << [model, attributes]
        provider
      end,
    )
  end
  let(:session) { AimHelm::Session.new(store: @store, config:) }
  let(:options) do
    AimHelm::Agent.new(instructions: "Answer accurately.", model: "gpt-5.6-luna")
  end
  let(:usage) { AimHelm::Usage.new(input_tokens: 10, output_tokens: 2) }
  let(:message) do
    AimHelm::Message.assistant(
      content: "Report ready",
      model: options.model,
      provider: :openai,
      usage:,
      stop_reason: :stop,
    )
  end
  let(:provider) { instance_double(AimHelm::Providers::OpenAI, close: nil) }

  it "streams tagged events and appends a complete turn progressively" do
    request = nil
    events = []
    allow(provider).to receive(:stream) do |**attributes, &emit|
      request = attributes.except(:messages).merge(
        message_roles: attributes.fetch(:messages).map(&:role),
      )
      emit.call(AimHelm::Event.build(type: :"message.delta", index: 0, delta: "Report ready"))
      message
    end

    outcome = described_class.call(
      prompt: "Summarize the report",
      options:,
      session:,
      emit: events.method(:<<),
    )

    expect(outcome).to be_success
    result = outcome.value!
    expect(result).to have_attributes(text: "Report ready", session:, run_id: result.run_id)
    expect(result.spend.tokens).to eq(usage.total_tokens)
    expect(result.subagents).to be_nil
    expect(request).to include(system: options.instructions, tools: [], output_schema: nil)
    expect(request.fetch(:message_roles)).to eq([:user])

    entries = session.entries
    expect(entries.map(&:kind)).to eq(%w[user assistant terminal])
    expect(entries[1].payload.fetch("usage")).to include(
      "input_tokens" => 10,
      "output_tokens" => 2,
    )
    expect(entries.map(&:run_id).uniq).to eq([result.run_id])
    expect(entries.last).to have_attributes(
      key: "terminal:#{result.run_id}",
      payload: { "outcome" => "done" },
    )

    expect(events.map(&:type)).to eq(
      %i[run.started turn.started message.delta run.completed],
    )
    expect(events).to all(have_attributes(session_id: session.id, run_id: result.run_id))
    turn_events = events.select(&:turn_id)
    expect(turn_events.map(&:type)).to eq(%i[turn.started message.delta])
    expect(turn_events.map(&:turn_id).uniq).to eq([entries[1].turn_id])
    expect(provider).to have_received(:close)
  end

  it "fails at a lifetime budget and refuses later turns with the same cap" do
    events = []
    budgeted = options.new(budget: AimHelm::Budget.new(tokens: usage.total_tokens))
    allow(provider).to receive(:stream).and_return(message)

    first = described_class.call(
      prompt: "Summarize the report",
      options: budgeted,
      session:,
      emit: events.method(:<<),
    )
    second = described_class.call(prompt: "Try again", options: budgeted, session:)

    expect(first).to be_failure
    reason, detail = first.failure
    expect(reason).to eq(:budget_exhausted)
    expect(JSON.parse(detail)).to include(
      "limit" => { "tokens" => usage.total_tokens },
      "spent" => hash_including("tokens" => usage.total_tokens),
      "exceeded" => "tokens",
    )
    expect(second).to be_failure
    expect(second.failure.first).to eq(:budget_exhausted)
    expect(provider).to have_received(:stream).once
    expect(session.entries.select { |entry| entry.kind == "terminal" }.map(&:payload)).to all(
      include("outcome" => "failed", "reason" => "budget_exhausted"),
    )
    expect(events.map(&:type)).to eq(%i[run.started turn.started run.failed])
  end

  it "compacts a completed turn near the model context limit" do
    long_usage = AimHelm::Usage.new(input_tokens: 840_000)
    long_message = message.new(usage: long_usage)
    summary = AimHelm::Message.assistant(
      content: "The report is ready.",
      model: "claude-haiku-4-5",
      provider: :anthropic,
      usage: AimHelm::Usage.new(input_tokens: 3),
      stop_reason: :stop,
    )
    responses = [long_message, summary]
    requests = []
    allow(provider).to receive(:stream) do |**request|
      requests << request
      responses.shift
    end
    configured = options.new(
      compaction: AimHelm::Compaction.new(
        model: "claude-haiku-4-5",
        threshold: 0.5,
        system: "Keep only durable facts.",
      ),
    )

    outcome = described_class.call(prompt: "Analyze everything", options: configured, session:)

    expect(outcome).to be_success
    entries = session.entries
    terminal = entries.find { |entry| entry.kind == "terminal" }
    compaction = entries.find { |entry| entry.kind == "compaction" }
    expect(entries.map(&:kind)).to eq(%w[user assistant terminal usage compaction])
    expect(compaction).to have_attributes(
      key: "compaction:#{terminal.id}",
      payload: {
        "summary" => "The report is ready.",
        "covers_through_entry_id" => terminal.id,
      },
    )
    expect(entries[-2].payload).to include("purpose" => "compaction")
    expect(AimHelm::Replay.messages(entries).first.text).to eq(
      "Earlier conversation summary:\nThe report is ready.",
    )
    expect(session.status).to eq(:completed)
    expect(requests.last.fetch(:system)).to eq("Keep only durable facts.")
    expect(resolved_models).to include(
      ["claude-haiku-4-5", hash_including(reasoning: nil)],
    )
  end

  it "takes one full transcript read and refreshes by entry cursor" do
    store = Class.new do
      attr_reader :cursors

      def initialize
        @entries = []
        @cursors = []
      end

      def append(session_id, kind, payload, key: nil, run_id: nil, turn_id: nil)
        return if key && @entries.any? { |entry| entry.key == key }

        entry = AimHelm::Session::Record.new(
          id: @entries.length + 1,
          session_id:,
          kind: kind.to_s,
          payload:,
          key:,
          run_id:,
          turn_id:,
          created_at: Time.now.utc,
        )
        @entries << entry
        entry
      end

      def entries(_session_id, after_id: nil)
        @cursors << after_id
        return @entries.dup unless after_id

        @entries.drop_while { |entry| entry.id <= after_id }
      end

      def transaction(&block) = block.call
    end.new
    cursor_session = AimHelm::Session.new(store:, config:)
    allow(provider).to receive(:stream).and_return(message)

    outcome = described_class.call(prompt: "Summarize", options:, session: cursor_session)

    expect(outcome).to be_success
    expect(store.cursors.count(nil)).to eq(1)
    expect(store.cursors.drop(1)).to all(be_a(Integer))
  end

  it "runs tools, persists their calls and results, and emits call-scoped events" do
    schema = AimHelm::Schema.define do
      required(:report_id).filled(:string)
    end
    tool = AimHelm::Tool.define("lookup", "Looks up a report", schema:) do |arguments, context|
      context.broadcast(:"report.loaded", report_id: arguments.fetch("report_id"))
      "Report ready"
    end
    tool_message = AimHelm::Message.assistant(
      content: [
        {
          type: "tool_call",
          id: "call-1",
          name: "lookup",
          arguments: { report_id: "report-1" },
        },
      ],
      model: options.model,
      provider: :openai,
      usage:,
      stop_reason: :tool_use,
    )
    responses = [tool_message, message]
    events = []
    allow(provider).to receive(:stream) { responses.shift }

    outcome = described_class.call(
      prompt: "Summarize the report",
      options: options.new(tools: [tool]),
      session:,
      emit: events.method(:<<),
    )

    expect(outcome).to be_success
    expect(session.entries.map(&:kind)).to eq(
      %w[user assistant tool_call tool_started tool_result assistant terminal],
    )
    result = session.entries.find { |entry| entry.kind == "tool_result" }
    expect(result).to have_attributes(
      key: "result:call-1",
      payload: { "call_id" => "call-1", "output" => "Report ready", "error" => false },
    )
    expect(events.map(&:type)).to eq(
      %i[
        run.started
        turn.started
        tool.started
        report.loaded
        tool.completed
        turn.started
        run.completed
      ],
    )
    expect(events.select(&:call_id)).to all(have_attributes(call_id: "call-1"))
    tool_turn_id = session.entries.find { |entry| entry.kind == "tool_call" }.turn_id
    tool_events = events.select(&:call_id)
    expect(tool_events).to all(have_attributes(turn_id: tool_turn_id))
    expect(events.select do |event|
      event.type == :"turn.started"
    end.map(&:turn_id).uniq.length).to eq(2)
  end

  it "binds each tool batch to the provider turn that requested it" do
    observed = []
    tools = %w[first second].map do |name|
      AimHelm::Tool.define(name, "Runs #{name}") do |_arguments, context|
        context.broadcast(:"tool.rendered", label: name)
        observed << [name, context.turn_id]
        "#{name} result"
      end
    end
    responses = [tool_message(call("first")), tool_message(call("second")), message]
    allow(provider).to receive(:stream) { responses.shift }

    outcome = described_class.call(
      prompt: "Run both in order",
      options: options.new(tools:),
      session:,
    )

    expect(outcome).to be_success
    assistant_turn_ids = session.entries.filter_map do |entry|
      entry.turn_id if entry.kind == "assistant"
    end
    expect(assistant_turn_ids.uniq.length).to eq(3)
    expect(observed).to eq(
      [
        ["first", assistant_turn_ids.fetch(0)],
        ["second", assistant_turn_ids.fetch(1)],
      ],
    )
    expect(session.entries.select { |entry| entry.kind.start_with?("tool_") }).to all(
      satisfy do |entry|
        call_id = entry.payload.fetch(entry.kind == "tool_call" ? "id" : "call_id")
        expected_turn_id = if call_id == "call-first"
                             assistant_turn_ids.fetch(0)
                           else
                             assistant_turn_ids.fetch(1)
                           end
        entry.turn_id == expected_turn_id
      end,
    )
  end

  it "runs free calls before parking the gated calls in a mixed batch" do
    free = AimHelm::Tool.define("free", "Runs freely") { "free result" }
    gated = AimHelm::Tool.define(
      "gated",
      "Needs approval",
      needs_approval: true,
    ) { "gated result" }
    responses = [tool_message(call("free"), call("gated")), message]
    events = []
    allow(provider).to receive(:stream) { responses.shift }

    outcome = described_class.call(
      prompt: "Run both",
      options: options.new(tools: [free, gated]),
      session:,
      emit: events.method(:<<),
    )

    expect(outcome).to be_success
    expect(outcome.value!).to be_awaiting_approval
    expect(outcome.value!.pending.map(&:call_id)).to eq(["call-gated"])
    expect(session.status).to eq(:awaiting_approval)
    kinds = session.entries.map(&:kind)
    expect(kinds.index("tool_result")).to be < kinds.index("approval_request")
    expect(kinds).not_to include("terminal")
    expect(events.map(&:type)).to include(:"tool.completed", :"tool.approval")
    expect(responses.size).to eq(1)
  end

  it "settles human-approved calls only after the whole gated batch is decided" do
    evaluations = 0
    executions = []
    tools = %w[first second].map do |name|
      AimHelm::Tool.define(
        name,
        "Runs #{name}",
        needs_approval: lambda do |_arguments, _context|
          evaluations += 1
          true
        end,
      ) do
        executions << name
        "#{name} result"
      end
    end
    responses = [tool_message(call("first"), call("second")), message]
    allow(provider).to receive(:stream) { responses.shift }
    parked = described_class.call(prompt: "Run both", options: options.new(tools:), session:)
    run_id = parked.value!.run_id

    AimHelm::Control.new(session:).decide(call_id: "call-first", verdict: :approve,
                                          decided_by: "user-1")
    partial = described_class.resume(run_id:, options: options.new(tools:), session:)

    expect(partial.value!).to be_awaiting_approval
    expect(partial.value!.pending.map(&:call_id)).to eq(["call-second"])
    expect(executions).to be_empty
    expect(session.status).to eq(:awaiting_approval)

    AimHelm::Control.new(session:).decide(call_id: "call-second", verdict: :approve,
                                          decided_by: "user-1")
    completed = described_class.resume(run_id:, options: options.new(tools:), session:)

    expect(completed.value!.text).to eq("Report ready")
    expect(executions).to contain_exactly("first", "second")
    expect(evaluations).to eq(6)
    parked_entries = session.entries.select do |entry|
      %w[tool_call approval_request approval_decision tool_started tool_result]
        .include?(entry.kind) && entry.run_id == run_id
    end
    expect(parked_entries.map(&:turn_id).uniq.length).to eq(1)
  end

  it "turns a denial into a tool result without invoking the handler" do
    executions = 0
    tool = AimHelm::Tool.define("gated", "Needs approval", needs_approval: true) do
      executions += 1
    end
    responses = [tool_message(call("gated")), message]
    replayed = nil
    allow(provider).to receive(:stream) do |messages:, **|
      replayed = messages
      responses.shift
    end
    parked = described_class.call(prompt: "Run it", options: options.new(tools: [tool]), session:)
    run_id = parked.value!.run_id
    AimHelm::Control.new(session:).decide(call_id: "call-gated", verdict: :deny,
                                          decided_by: "user-1")

    completed = described_class.resume(run_id:, options: options.new(tools: [tool]), session:)

    expect(completed).to be_success
    expect(executions).to eq(0)
    result = replayed.find { |item| item.tool_call_id == "call-gated" }
    expect(result).to have_attributes(role: :tool, tool_error: true)
    expect(result.text).to eq("The user denied this tool call.")
  end

  it "records an allow-rule decision before executing a gated call" do
    tool = AimHelm::Tool.define(
      "gated",
      "Needs approval",
      identifier: "reports/gated",
      needs_approval: true,
    ) { "ready" }
    responses = [tool_message(call("gated")), message]
    authorize = ->(**) { "rule-1" }
    events = []
    allow(provider).to receive(:stream) { responses.shift }

    outcome = described_class.call(
      prompt: "Run it",
      options: options.new(tools: [tool]),
      session:,
      authorize:,
      emit: events.method(:<<),
    )

    expect(outcome.value!.text).to eq("Report ready")
    entries = session.entries
    decision = entries.find { |entry| entry.kind == "approval_decision" }
    expect(decision.payload).to include(
      "call_id" => "call-gated",
      "source" => "rule",
      "decided_by" => "rule-1",
      "rule" => "rule-1",
    )
    kinds = entries.map(&:kind)
    expect(kinds.index("approval_decision")).to be < kinds.index("tool_started")
    expect(events.map(&:type)).to include(:"tool.approval", :"tool.approved")
    expect(events.index { |event| event.type == :"tool.approved" })
      .to be < events.index { |event| event.type == :"tool.started" }
  end

  it "recovers a started call as interrupted instead of executing it twice" do
    run_id = SecureRandom.uuid_v7
    executions = 0
    tool = AimHelm::Tool.define("lookup", "Looks up") do
      executions += 1
      "ready"
    end
    interrupted = tool_message(call("lookup"))
    turn_id = SecureRandom.uuid_v7
    session.append(:user, { content: AimHelm::Message.user("Lookup").content }, run_id:)
    session.append(
      :assistant,
      {
        content: interrupted.content,
        model: interrupted.model,
        provider: interrupted.provider,
        stop_reason: interrupted.stop_reason,
      },
      run_id:,
      turn_id:,
    )
    session.append(:tool_call, call("lookup"), key: "call:call-lookup", run_id:, turn_id:)
    session.append(:tool_started, { call_id: "call-lookup" },
                   key: "started:call-lookup", run_id:, turn_id:)
    replayed = nil
    on_interrupted_tool = spy("interrupted tool handler")
    allow(provider).to receive(:stream) do |messages:, **|
      replayed = messages
      message
    end

    described_class.resume(
      run_id:,
      options: options.new(tools: [tool]),
      session:,
      on_interrupted_tool:,
    )

    expect(executions).to eq(0)
    result = replayed.find { |item| item.tool_call_id == "call-lookup" }
    expect(result.text).to eq(AimHelm::Tools::Batch::INTERRUPTED)
    result = session.entries.find { |entry| entry.kind == "tool_result" }
    expect(result.payload).to include("call_id" => "call-lookup", "error" => true)
    expect(on_interrupted_tool).to have_received(:call).with(
      tool_call: call("lookup"),
      entries: include(have_attributes(kind: "tool_started")),
    )
  end

  it "continues a session from its durable transcript" do
    requests = []
    allow(provider).to receive(:stream) do |messages:, **|
      requests << messages.map(&:role)
      message
    end

    first = described_class.call(prompt: "First", options:, session:)
    second = described_class.call(prompt: "Second", options:, session:)

    expect(first).to be_success
    expect(second).to be_success
    expect(requests).to eq([[:user], %i[user assistant user]])
    expect(session.entries.select { |entry| entry.kind == "terminal" }.size).to eq(2)
  end

  it "resumes an open turn without appending its user entry again" do
    run_id = SecureRandom.uuid_v7
    session.append(:user, { content: [{ type: "text", text: "Resume me" }] }, run_id:)
    request = nil
    allow(provider).to receive(:stream) do |messages:, **|
      request = messages.dup
      message
    end

    outcome = described_class.resume(run_id:, options:, session:)

    expect(outcome).to be_success
    expect(request.map(&:role)).to eq([:user])
    expect(session.entries.map(&:kind)).to eq(%w[user assistant terminal])
    expect(session.entries.map(&:run_id).uniq).to eq([run_id])
  end

  it "finalizes a completed assistant without calling the provider again" do
    run_id = SecureRandom.uuid_v7
    allow(provider).to receive(:stream)
    session.append(:user, { content: AimHelm::Message.user("Resume me").content }, run_id:)
    session.append(
      :assistant,
      {
        content: message.content,
        model: message.model,
        provider: message.provider,
        stop_reason: message.stop_reason,
        usage: {
          input_tokens: usage.input_tokens,
          output_tokens: usage.output_tokens,
          cost: 0.001,
          wall_clock: 1.0,
        },
      },
      run_id:,
    )

    outcome = described_class.resume(run_id:, options:, session:)

    expect(outcome).to be_success
    expect(outcome.value!.text).to eq("Report ready")
    expect(provider).not_to have_received(:stream)
    expect(session.entries.map(&:kind)).to eq(%w[user assistant terminal])
  end

  it "folds messages queued during a run before completing the turn" do
    requests = []
    responses = [message, message]
    allow(provider).to receive(:stream) do |messages:, **|
      requests << messages.dup
      if requests.one?
        control = AimHelm::Control.new(session:)
        control.queue_message(content: "Include the appendix", key: "message:1")
      end
      responses.shift
    end

    outcome = described_class.call(prompt: "Summarize", options:, session:)

    expect(outcome).to be_success
    expect(provider).to have_received(:stream).twice
    expect(requests.last.map(&:role)).to eq(%i[user assistant user])
    expect(requests.last.last.text).to eq("Include the appendix")
    expect(session.pending_messages).to be_empty
  end

  it "honors a durable stop before resuming provider work" do
    run_id = "turn-1"
    events = []
    session.append(:user, { content: AimHelm::Message.user("Wait").content }, run_id:)
    session.append(:stop_request, {}, key: "stop:turn-1", run_id:)
    allow(provider).to receive(:stream)

    outcome = described_class.resume(
      run_id:,
      options:,
      session:,
      emit: events.method(:<<),
    )

    expect(outcome).to be_failure
    expect(outcome.failure).to eq([:cancelled, nil])
    expect(provider).not_to have_received(:stream)
    expect(session.entries.last).to have_attributes(
      kind: "terminal",
      payload: { "outcome" => "stopped", "reason" => "cancelled" },
    )
    expect(events.map(&:type)).to eq([:"run.stopped"])
  end

  it "replays a dangling tool call without executing it again" do
    run_id = SecureRandom.uuid_v7
    calls = 0
    tool = AimHelm::Tool.define("lookup", "Looks up a report") do
      calls += 1
      "ready"
    end
    interrupted = AimHelm::Message.assistant(
      content: [{ type: "tool_call", id: "call-1", name: "lookup", arguments: {} }],
      model: options.model,
      provider: :openai,
      usage: nil,
      stop_reason: :tool_use,
    )
    session.append(:user, { content: [{ type: "text", text: "Lookup" }] }, run_id:)
    session.append(
      :assistant,
      {
        content: interrupted.content,
        model: interrupted.model,
        provider: interrupted.provider,
        stop_reason: interrupted.stop_reason,
      },
      run_id:,
    )
    replayed = nil
    allow(provider).to receive(:stream) do |messages:, **|
      replayed = messages.dup
      message
    end

    outcome = described_class.resume(
      run_id:,
      options: options.new(tools: [tool]),
      session:,
    )

    expect(outcome).to be_success
    expect(calls).to eq(0)
    expect(replayed.map(&:role)).to eq(%i[user assistant tool])
    expect(replayed.last.text).to eq(AimHelm::Replay::INTERRUPTED_TOOL_RESULT)
  end

  it "raises transient provider failures without closing the turn" do
    run_id = SecureRandom.uuid_v7
    session.append(:user, { content: [{ type: "text", text: "Try later" }] }, run_id:)
    error = AimHelm::OverloadedError.new("busy")
    allow(provider).to receive(:stream).and_raise(error)

    expect do
      described_class.resume(run_id:, options:, session:)
    end.to raise_error(AimHelm::OverloadedError, "busy")

    expect(session.entries.map(&:kind)).to eq(["user"])
    expect(session.pending_run_id).to eq(run_id)
  end

  it "returns provider failures after writing a failed terminal" do
    error = AimHelm::ProviderError.new("unavailable")
    events = []
    allow(provider).to receive(:stream).and_raise(error)

    outcome = described_class.call(
      prompt: "Summarize the report",
      options:,
      session:,
      emit: events.method(:<<),
    )

    expect(outcome).to be_failure
    expect(outcome.failure).to eq([:provider_error, "unavailable"])
    expect(session.entries.last).to have_attributes(
      kind: "terminal",
      payload: {
        "outcome" => "failed",
        "reason" => "provider_error",
        "error" => "unavailable",
      },
    )
    expect(events.map(&:type)).to eq(%i[run.started turn.started run.failed])
  end

  it "raises unexpected exceptions after writing a failed terminal" do
    events = []
    allow(provider).to receive(:stream).and_raise("broken")

    expect do
      described_class.call(
        prompt: "Summarize the report",
        options:,
        session:,
        emit: events.method(:<<),
      )
    end.to raise_error(RuntimeError, "broken")

    expect(session.entries.last.payload).to eq(
      "outcome" => "failed",
      "reason" => "exception",
      "error" => "broken",
    )
    expect(events.map(&:type)).to eq(%i[run.started turn.started run.failed])
  end

  it "uses the Agent#run block instead of an explicit events callback" do
    explicit_events = []
    block_events = []
    allow(provider).to receive(:stream).and_return(message)

    options.with(provider:).run(
      "Summarize the report",
      session:,
      events: explicit_events.method(:<<),
    ) { |event| block_events << event }

    expect(explicit_events).to be_empty
    expect(block_events.map(&:type)).to eq(%i[run.started turn.started run.completed])
  end

  it "reports append anomalies through process telemetry" do
    store = Class.new do
      def append(session_id, kind, payload, key: nil, run_id: nil, turn_id: nil)
        if kind == :terminal
          return AimHelm::Session::Record.new(
            id: 1,
            session_id:,
            kind: kind.to_s,
            payload:,
            key:,
            run_id:,
            turn_id:,
            created_at: Time.now.utc,
          )
        end

        raise IOError, "append failed"
      end

      def entries(*) = []
      def transaction(&block) = block.call
    end.new
    observations = []
    config = AimHelm.config.with(
      telemetry: ->(event, **payload) { observations << [event, payload] },
    )

    expect do
      described_class.call(
        prompt: "Summarize the report",
        options:,
        session: AimHelm::Session.new(store:, config:),
      )
    end.to raise_error(IOError, "append failed")

    expect(observations).to contain_exactly(
      [
        :append_anomaly,
        hash_including(count: 1, kind: "user", error_class: "IOError"),
      ],
    )
  end

  def tool_message(*calls)
    AimHelm::Message.assistant(
      content: calls,
      model: options.model,
      provider: :openai,
      usage:,
      stop_reason: :tool_use,
    )
  end

  def call(name)
    {
      "type" => "tool_call",
      "id" => "call-#{name}",
      "name" => name,
      "arguments" => {},
    }
  end
end
