# frozen_string_literal: true

module AimHelm
  module Events
    # Renews the session lease from event traffic before forwarding to `sink`, at most once per
    # interval, and raises LeaseLostError as soon as the store shows another worker holding it.
    class LeasedSink < Dry::Struct
      HEARTBEAT_INTERVAL = 30

      attribute :interval, Types::Coercible::Float.constrained(gt: 0).default(HEARTBEAT_INTERVAL)
      attribute :lease, Types.Interface(:heartbeat?)
      attribute :session, Types.Instance(AimHelm::Session)
      attribute :sink, Types.Interface(:call, :close)

      def call(event)
        heartbeat
        sink.call(event)
      end

      def close = sink.close

      private

      # Lease#heartbeat? is scoped to this lease token, so a reclaimed session fails the check.
      def heartbeat
        now = monotonic_time
        last = @last_heartbeat_at ||= now
        return if now - last < interval

        unless lease.heartbeat?
          raise LeaseLostError, "session #{session.id} lease ownership was lost"
        end

        @last_heartbeat_at = now
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
