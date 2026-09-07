# frozen_string_literal: true

require "aim_helm"
require "tmpdir"
require "webmock/rspec"

require_relative "support/store_contract"
require_relative "support/subagent_host_contract"

module FixtureHelpers
  def fixture(name)
    File.read(File.expand_path("fixtures/#{name}", __dir__))
  end

  def sse_records(name, chunk_size: 17)
    source = fixture(name)
    parser = AimHelm::Providers::Streaming::SSE.new
    records = []
    offset = 0

    while offset < source.bytesize
      chunk = source.byteslice(offset, chunk_size)
      parser.feed(chunk) { |record| records << record }
      offset += chunk.bytesize
    end
    parser.finish { |record| records << record }
    records
  end

  def session_entry(kind, payload, id: 1)
    AimHelm::Session::Record.new(
      id:,
      session_id: "session-1",
      kind: kind.to_s,
      payload:,
      run_id: "turn-1",
      created_at: Time.at(0).utc,
    )
  end

  def replay_fixture_entries(message)
    tool_call = message.tool_calls.fetch(0)
    [
      session_entry(:user, { content: [{ type: "text", text: "First question" }] }, id: 1),
      session_entry(:terminal, { outcome: "failed" }, id: 2),
      session_entry(:user, { content: [{ type: "text", text: "Try again" }] }, id: 3),
      session_entry(
        :assistant,
        {
          content: message.content,
          model: message.model,
          provider: message.provider,
          stop_reason: message.stop_reason,
        },
        id: 4,
      ),
      session_entry(:tool_call, tool_call, id: 5),
      session_entry(
        :tool_result,
        { call_id: tool_call.fetch("id"), output: "sunny", error: false },
        id: 6,
      ),
    ]
  end
end

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.include FixtureHelpers

  config.around(:each, :live) do |example|
    WebMock.allow_net_connect!
    example.run
  ensure
    WebMock.disable_net_connect!
  end
end
