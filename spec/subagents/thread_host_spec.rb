# frozen_string_literal: true

RSpec.describe AimHelm::Subagents::ThreadHost do
  around do |example|
    provider_factory = AimHelm.config.provider_factory
    Dir.mktmpdir("aim_helm-subagent-host") do |dir|
      @store = AimHelm::Stores::JSONL.new(dir:)
      AimHelm.configure do |config|
        config.provider_factory = lambda do |model, **|
          AimHelm::Providers::Fake.new(model:, turns: [{ text: "Child complete" }])
        end
      end
      example.run
    ensure
      @subagent_host&.close
    end
  ensure
    AimHelm.configure { |config| config.provider_factory = provider_factory }
  end

  let(:options) do
    AimHelm::Agent.new(instructions: "Coordinate.", model: "gpt-5.6-luna", subagents: [])
  end
  let(:parent_session) { AimHelm::Session.new(store: @store, id: "parent-1") }
  let(:subagent_host) { @subagent_host = described_class.new(options:) }
  let(:events) { [] }
  let(:parent_context) do
    AimHelm::Tools::Context.new(
      session: parent_session,
      events: AimHelm::Tools::Broadcaster.new(sink: events.method(:<<), call_id: "call-1"),
      app: Object.new,
      run_id: "parent-run-1",
      turn_id: "parent-turn-1",
      call_id: "call-1",
    )
  end
  let(:child_session) do
    lambda do |id|
      AimHelm::Session.new(store: @store, id:, config: parent_session.config)
    end
  end
  let(:child_record) do
    lambda do |mode|
      AimHelm::Subagents::Record.new(
        session_id: SecureRandom.uuid_v7,
        parent_session_id: parent_session.id,
        run_id: SecureRandom.uuid_v7,
        parent_run_id: parent_context.run_id,
        call_id: parent_context.call_id,
        name: "researcher",
        task: "Research",
        mode:,
        options: AimHelm::Agent::Record.capture(options: options.new(subagents: nil)),
      )
    end
  end
  let(:finish_background) do
    lambda do |record|
      subagent_host.read(id: record.session_id, wait: true, timeout: 5, context: parent_context)
    end
  end

  it_behaves_like "a AimHelm subagent host"

  it "links the child to its parent turn before dispatch" do
    record = child_record.call(:background)

    subagent_host.spawn(record:, context: parent_context)

    expect(events).to include(
      have_attributes(
        type: :"subagent.spawned",
        call_id: record.call_id,
        name: record.name,
        payload: {
          "subagent_run_id" => record.run_id,
          "subagent_session_id" => record.session_id,
          "task" => record.task,
        },
      ),
    )
    expect(parent_session.entries.last).to have_attributes(turn_id: parent_context.turn_id)
  end
end
