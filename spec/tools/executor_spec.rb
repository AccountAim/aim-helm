# frozen_string_literal: true

RSpec.describe AimHelm::Tools::Executor do
  let(:session) { AimHelm::Session.new(store: AimHelm::Stores::Memory.new, id: "session-1") }

  let(:snapshot) do
    AimHelm::Tool.define("snapshot", description: "Captures a preview.") do |_arguments, _context|
      AimHelm::Tool::Result.success(
        content: [
          "Preview at 1024x768.",
          AimHelm::Image.data("png-bytes", media_type: "image/png"),
        ],
        metadata: { widget: { id: "w1" } },
      )
    end
  end

  let(:executor) do
    described_class.new(
      tools: [snapshot],
      session:,
      run_id: "run-1",
      turn_id: "turn-1",
      emit: ->(event) { event },
    )
  end

  it "returns invalid arguments as an error result instead of failing the batch" do
    strict = AimHelm::Tool.define(
      "strict",
      description: "Requires a bounded size.",
      schema: AimHelm::Schema.define { required(:size).filled(:integer, lteq?: 10) },
    ) { |_arguments, _context| "unreachable" }
    strict_executor = described_class.new(
      tools: [strict],
      session:,
      run_id: "run-1",
      turn_id: "turn-1",
      emit: ->(event) { event },
    )

    results = strict_executor.call(
      [{ "id" => "call_1", "name" => "strict", "arguments" => { "size" => 99 } }],
    )

    expect(results.first).to include(call_id: "call_1", error: true)
    expect(results.first[:output]).to include("less than or equal to 10")
  ensure
    strict_executor.shutdown
  end

  it "keeps block-array tool output structured for replay" do
    results = executor.call(
      [{ "id" => "call_1", "name" => "snapshot", "arguments" => {} }],
    )

    expect(results).to eq(
      [
        {
          call_id: "call_1",
          output: [
            { "type" => "text", "text" => "Preview at 1024x768." },
            {
              "type" => "image",
              "source" => {
                "type" => "base64",
                "media_type" => "image/png",
                "data" => ["png-bytes"].pack("m0"),
              },
            },
          ],
          error: false,
          metadata: { "widget" => { "id" => "w1" } },
        },
      ],
    )
  ensure
    executor.shutdown
  end
end
