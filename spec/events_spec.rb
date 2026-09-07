# frozen_string_literal: true

RSpec.describe "AimHelm event sinks" do
  it "coalesces adjacent deltas and flushes before a lifecycle event" do
    received = []
    sink = AimHelm::Events::Coalesced.new(sink: received.method(:<<), interval: 1)
    first = event(:"message.delta", delta: "hel", sequence: 1)
    second = event(:"message.delta", delta: "lo", sequence: 2)

    sink.call(first)
    sink.call(second)
    sink.call(event(:"run.completed"))
    sink.close

    expect(received.map(&:type)).to eq(%i[message.delta run.completed])
    expect(received.first.delta).to eq("hello")
    expect(received.first.sequence).to eq(2)
  end

  it "keeps the newest partial tool-call snapshot on a merged delta" do
    received = []
    sink = AimHelm::Events::Coalesced.new(sink: received.method(:<<), interval: 1)
    first = event(:"tool.delta", delta: '{"q":', arguments: {})
    second = event(:"tool.delta", delta: '"ruby"}', arguments: { "q" => "ruby" })

    sink.call(first)
    sink.call(second)
    sink.close

    expect(received.one?).to be(true)
    expect(received.first.delta).to eq('{"q":"ruby"}')
    expect(received.first.arguments).to eq("q" => "ruby")
  end

  it "coalesces configured broadcast deliveries without losing routing context" do
    received = []
    context = Object.new
    sink = AimHelm::Events::Coalesced.new(sink: received.method(:<<), interval: 1)
    first = delivery(event(:"message.delta", delta: "hel", sequence: 1), context:)
    second = delivery(event(:"message.delta", delta: "lo", sequence: 2), context:)

    sink.call(first)
    sink.call(second)
    sink.close

    expect(received).to contain_exactly(
      have_attributes(
        session: first.session,
        context:,
        event: have_attributes(delta: "hello", sequence: 2),
      ),
    )
  end

  it "writes one JSON line through a logger-compatible object" do
    logger = Class.new do
      attr_reader :lines

      def initialize = @lines = []
      def info(line) = lines << line
    end.new
    sink = AimHelm::Events::Logger.new(logger:)

    sink.call(event(:"message.delta", delta: "hello"))

    expect(logger.lines).to contain_exactly(
      a_string_matching(/\A\[aim_helm\] message\.delta .*"delta":"hello"/),
    )
  end

  it "throttles lease renewal while forwarding every event" do
    lease = instance_double("Lease", heartbeat?: true)
    downstream = instance_double("Sink", call: nil, close: nil)
    sink = AimHelm::Events::LeasedSink.new(session:, lease:, sink: downstream)
    allow(sink).to receive(:monotonic_time).and_return(0.0, 29.0, 30.0, 30.1)

    4.times { sink.call(event(:"message.delta", delta: "hello")) }
    sink.close

    expect(lease).to have_received(:heartbeat?).once
    expect(downstream).to have_received(:call).exactly(4).times
    expect(downstream).to have_received(:close).once
  end

  it "stops forwarding when lease ownership is lost" do
    lease = instance_double("Lease", heartbeat?: false)
    downstream = instance_double("Sink", call: nil, close: nil)
    sink = AimHelm::Events::LeasedSink.new(session:, lease:, sink: downstream)
    allow(sink).to receive(:monotonic_time).and_return(0.0, 30.0)
    sink.call(event(:"message.delta", delta: "hello"))

    expect { sink.call(event(:"message.delta", delta: "again")) }
      .to raise_error(AimHelm::LeaseLostError, /ownership was lost/)
    expect(downstream).to have_received(:call).once
  end

  it "serializes simultaneous first events through one owner" do
    received = Queue.new
    sink = AimHelm::Events::Coalesced.new(sink: received.method(:<<))
    threads = 5.times.map do
      Thread.new { sink.call(event(:"run.started")) }
    end
    threads.each(&:join)
    sink.close

    expect(5.times.map { received.pop }.map(&:type)).to all(eq(:"run.started"))
  end

  it "reports a downstream failure and delivers the next event" do
    received = []
    observations = []
    attempts = 0
    downstream = lambda do |item|
      attempts += 1
      raise IOError, "unavailable" if attempts == 1

      received << item
    end
    telemetry = ->(name, **payload) { observations << [name, payload] }
    sink = AimHelm::Events::Coalesced.new(sink: downstream, telemetry:)

    sink.call(event(:"run.started"))
    sink.call(event(:"run.completed"))
    sink.close

    expect(received.map(&:type)).to eq([:"run.completed"])
    expect(observations).to contain_exactly(
      [:sink_failed, { count: 1, error_class: "IOError" }],
    )
  end

  def event(type, **fields)
    AimHelm::Event.build(type:, index: 0, call_id: "call-1", **fields).with(
      session_id: "session-1",
      run_id: "run-1",
      turn_id: "turn-1",
    )
  end

  def delivery(event, context: nil)
    AimHelm::Events::Delivery.new(event:, session:, context:)
  end

  def session
    store = Class.new do
      def append(*) = nil
      def entries(*) = []
      def transaction(&block) = block.call
    end.new
    AimHelm::Session.new(store:, id: "session-1")
  end
end
