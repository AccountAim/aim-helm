# frozen_string_literal: true

module AimHelm
  # One runtime notification. `type` must read `namespace.event`, with further dotted segments
  # allowed; RESERVED lists the types AimHelm itself emits, which Tools::Broadcaster refuses to
  # let application code reuse. Fields outside the declared attributes fall into `payload`.
  class Event < Dry::Struct
    RESERVED = %i[
      message.delta
      provider.failed
      run.completed
      run.failed
      run.queued
      run.started
      run.stopped
      subagent.spawned
      subagent.waiting
      thinking.delta
      tool.approval
      tool.approved
      tool.completed
      tool.delta
      tool.denied
      tool.discovered
      tool.failed
      tool.requested
      tool.started
      turn.completed
      turn.started
      usage.reported
    ].freeze

    TYPE_PATTERN = /\A[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+\z/

    TYPE = Types::Symbol.constructor do
      name = it.to_s

      unless TYPE_PATTERN.match?(name)
        raise ArgumentError, "event type must use namespace.event: #{name.inspect}"
      end

      name.to_sym
    end

    attribute :payload, Types::JsonObject.default(Types::EMPTY_HASH)
    attribute :type, TYPE
    attribute? :arguments, Types::JsonObject.optional
    attribute? :call_id, Types::String
    attribute? :delta, Types::String
    attribute? :error, Types::String
    attribute? :index, Types::Coercible::Integer
    attribute? :message, Types.Instance(Message)
    attribute? :name, Types::String
    attribute? :reason, Types::Coercible::Symbol
    attribute? :run_id, Types::String
    attribute? :sequence, Types::Coercible::Integer
    attribute? :session_id, Types::String
    attribute? :title, Types::String
    attribute? :turn_id, Types::String
    attribute? :usage, Types.Instance(Usage)

    FIELDS = (schema.keys.map(&:name) - %i[type payload]).freeze

    # { type: :"report.loaded", report_id: "1" } -> payload: { "report_id" => "1" }
    def self.build(type:, **fields)
      known = fields.slice(*FIELDS)
      new(type:, **known, payload: fields.except(*FIELDS)).freeze
    end

    def with(**attributes) = new(**attributes).freeze
  end
end
