# frozen_string_literal: true

RSpec.describe AimHelm::Event do
  it "separates normalized fields from custom JSON payload" do
    event = described_class.build(type: "report.loaded", index: "2", report_id: "report-1")

    expect(event).to be_frozen
    expect(event).to have_attributes(
      type: :"report.loaded",
      index: 2,
      payload: { "report_id" => "report-1" },
    )
    expect(event.to_h).to include(
      type: :"report.loaded",
      payload: { "report_id" => "report-1" },
    )
  end

  it "adds channel tags without mutating the source event" do
    event = described_class.build(type: :"report.loaded")
    tagged = event.with(
      session_id: "session-1",
      run_id: "run-1",
      turn_id: "turn-1",
      call_id: "call-1",
    )

    expect(event).to have_attributes(session_id: nil, run_id: nil, turn_id: nil, call_id: nil)
    expect(tagged).to be_frozen
    expect(tagged).to have_attributes(
      session_id: "session-1",
      run_id: "run-1",
      turn_id: "turn-1",
      call_id: "call-1",
    )
  end

  it "requires one namespace and event" do
    expect { described_class.build(type: :report_loaded) }
      .to raise_error(Dry::Struct::Error, /event type must use namespace\.event/)
  end
end
