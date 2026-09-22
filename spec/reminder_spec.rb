# frozen_string_literal: true

RSpec.describe AimHelm::Reminder do
  around do |example|
    Dir.mktmpdir("aim_helm-reminder") do |dir|
      @session = AimHelm::Session.new(store: AimHelm::Stores::JSONL.new(dir:))
      example.run
    end
  end

  it "uses its interval and optional lead-in" do
    periodic = described_class.new(text: "Focus.", every: 3)
    early = described_class.new(text: "Focus.", every: 3, after: 1)

    expect((0..6).select { |turns| periodic.due?(turns) }).to eq([3, 6])
    expect((0..6).select { |turns| early.due?(turns) }).to eq([1, 4])
  end

  it "adds all due reminders to one request-only system-reminder block" do
    provider = AimHelm::Providers::Fake.new(
      turns: [
        { tool_calls: [{ name: "noop", arguments: {} }] },
        { text: "done" },
      ],
    )
    noop = AimHelm::Tool.define("noop", "Returns immediately") { "ok" }
    options = AimHelm::Agent.new(
      instructions: "Work carefully.",
      model: "gpt-6-luna",
      tools: [noop],
      reminders: [
        described_class.new(text: "Stay focused.", every: 1),
        described_class.new(text: "Check the budget.", every: 1),
      ],
    )

    options.with(provider:).run("Start", session: @session)

    reminders = provider.requests.last.fetch(:messages).select do |message|
      message.text.include?("<system-reminder>")
    end
    expect(reminders.length).to eq(1)
    expect(reminders.first.text).to include("Stay focused.", "Check the budget.")
    expect(AimHelm::Replay.messages(@session.entries).map(&:text).join)
      .not_to include("<system-reminder>")
  end
end
