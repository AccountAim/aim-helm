# frozen_string_literal: true

module AimHelm
  module Events
    # Fans one event out to both subscriber seams: the caller's foreground sink — the block or
    # `events:` given to Agent#run — first, then config.broadcast, wrapped in a Delivery with the
    # session and app context. `active?` is falsy when neither is wired, so callers skip it.
    class Subscribers < Dry::Struct
      attribute :broadcast, Types.Interface(:call).optional.default(nil)
      attribute :context, Types.Instance(Object).optional.default(nil)
      attribute :foreground, Types.Interface(:call).optional.default(nil)
      attribute :session, Types.Instance(AimHelm::Session)

      def call(event)
        foreground&.call(event)
        broadcast&.call(Delivery.new(event:, session:, context:))
        event
      end

      def active? = foreground || broadcast
    end
  end
end
