# frozen_string_literal: true

module AimHelm
  module Stores
    class ActiveRecord
      # Curries the host's authorize callback with the session's persisted context.
      class Authorization < Dry::Struct
        attribute :callback, Types.Interface(:call)
        attribute :context, Types.Instance(Object)

        def call(**attributes) = callback.call(context:, **attributes)
      end
    end
  end
end
