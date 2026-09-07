# frozen_string_literal: true

module AimHelm
  module Events
    # What config.broadcast receives: one event plus the session and application context needed to
    # route it to a transport.
    class Delivery < Dry::Struct
      attribute :context, Types.Instance(Object).optional.default(nil)
      attribute :event, Types.Instance(AimHelm::Event)
      attribute :session, Types.Instance(AimHelm::Session)
    end
  end
end
