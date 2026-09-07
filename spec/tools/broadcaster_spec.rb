# frozen_string_literal: true

RSpec.describe AimHelm::Tools::Broadcaster do
  let(:events) { [] }
  let(:broadcaster) { described_class.new(sink: events.method(:<<), call_id: "call-1") }

  it "builds call-scoped application events from keyword arguments" do
    broadcaster.call(type: :"report.loaded", report_id: "report-1")

    expect(events).to contain_exactly(
      have_attributes(
        type: :"report.loaded",
        call_id: "call-1",
        payload: { "report_id" => "report-1" },
      ),
    )
  end

  it "rejects AimHelm lifecycle event names" do
    expect { broadcaster.call(type: :"subagent.spawned") }
      .to raise_error(AimHelm::ReservedEventError, "subagent.spawned")
    expect(events).to be_empty
  end

  it "publishes normalized lifecycle events through the same call scope" do
    broadcaster.publish(
      AimHelm::Event.build(type: :"subagent.waiting", subagent_session_id: "child-1"),
    )

    expect(events).to contain_exactly(
      have_attributes(
        type: :"subagent.waiting",
        call_id: "call-1",
        payload: { "subagent_session_id" => "child-1" },
      ),
    )
  end
end
