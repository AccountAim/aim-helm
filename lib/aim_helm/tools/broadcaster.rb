# frozen_string_literal: true

module AimHelm
  module Tools
    # The event sink a tool sees, stamping the running call_id onto everything it emits. `call`
    # is the tool-facing path and refuses AimHelm's reserved types; `publish` takes an already
    # built event and skips that check, which is how hosts emit reserved `subagent.waiting`.
    class Broadcaster < Dry::Struct
      attribute :call_id, Types::String
      attribute :sink, Types.Interface(:call)

      def call(type:, **fields)
        event = Event.build(type:, **fields)
        raise ReservedEventError, event.type.to_s if Event::RESERVED.include?(event.type)

        publish(event)
      end

      def publish(event) = sink.call(event.with(call_id:))
    end
  end
end
