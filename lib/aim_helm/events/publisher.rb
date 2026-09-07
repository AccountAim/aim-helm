# frozen_string_literal: true

module AimHelm
  module Events
    # Serializes delivery onto one owner thread and blocks the caller until the sink returns, so
    # events reach the sink in publish order and a sink failure raises on the calling thread.
    # With no sink, `call` and `close` do nothing.
    class Publisher < Dry::Struct
      CLOSE = Object.new.freeze

      attribute :sink, Types.Interface(:call).optional.default(nil)

      def initialize(...)
        super
        return unless sink

        @queue = Queue.new
        @owner = Thread.new { deliver }
      end

      def call(event)
        return event unless sink

        response = Queue.new
        @queue << [event, response]
        status, value = response.pop
        raise value if status == :error

        event
      end

      def close
        return unless @owner

        @queue << CLOSE
        @owner.join
      end

      private

      def deliver
        loop do
          item = @queue.pop
          break if item.equal?(CLOSE)

          event, response = item

          begin
            sink.call(event)
            response << [:ok, nil]
          # The caller re-raises failures on its own execution thread.
          # rubocop:disable Lint/RescueException
          rescue Exception => e
            # rubocop:enable Lint/RescueException
            response << [:error, e]
          end
        end
      end
    end
  end
end
