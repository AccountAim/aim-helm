# frozen_string_literal: true

module AimHelm
  module Events
    # Batches adjacent deltas before forwarding them to `sink`. Accepts bare Events from
    # Agent#run(events:) or Delivery envelopes from config.broadcast; owners close per-run sinks,
    # while process-wide sinks flush at every non-delta lifecycle event.
    class Coalesced < Dry::Struct
      DELTAS = %i[message.delta thinking.delta tool.delta].freeze
      CLOSE = Object.new.freeze

      attribute :interval, Types::Coercible::Float.constrained(gt: 0).default(0.05)
      attribute(:logger, Types.Interface(:error).default { ::Logger.new($stdout) })
      attribute :sink, Types.Interface(:call)
      attribute(:telemetry, Types.Interface(:call).default { Telemetry })

      def initialize(...)
        super
        @queue = Queue.new
        @owner = Thread.new { run }
      end

      def call(event)
        @queue << event
        event
      end

      def close
        @queue << CLOSE if @owner.alive?
        @owner.join
      end

      def to_proc = method(:call).to_proc

      private

      def run
        loop do
          event = next_event

          if event.equal?(CLOSE)
            flush
            break
          elsif event
            accept(event)
          else
            flush
          end
        end
      end

      def next_event
        return @queue.pop unless @buffer

        remaining = @flush_at - monotonic_time
        return if remaining <= 0

        @queue.pop(timeout: remaining)
      end

      def accept(item)
        event = event_for(item)

        unless DELTAS.include?(event.type)
          flush
          deliver(item)
          return
        end

        if same_stream?(event)
          merged = event.with(
            delta: event_for(@buffer).delta.to_s + event.delta.to_s,
            arguments: event.arguments,
          )
          @buffer = replace_event(@buffer, merged)
        else
          flush
          @buffer = item
          @flush_at = monotonic_time + interval
        end
      end

      def same_stream?(event)
        return false unless @buffer

        buffered = event_for(@buffer)

        %i[call_id index run_id session_id turn_id type].all? do
          buffered.public_send(it) == event.public_send(it)
        end
      end

      def event_for(item)
        item.is_a?(Event) ? item : item.event
      end

      def replace_event(item, event)
        item.is_a?(Event) ? event : item.new(event:)
      end

      def flush
        event = @buffer
        @buffer = nil
        deliver(event) if event
      end

      # A failing sink is logged, never raised: the owner thread has to keep draining the queue.
      def deliver(event)
        sink.call(event)
      rescue StandardError => e
        telemetry.call(:sink_failed, count: 1, error_class: e.class.name)
        logger.error("AimHelm sink failed: #{e.message}")
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
