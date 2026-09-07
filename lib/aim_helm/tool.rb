# frozen_string_literal: true

module AimHelm
  # A function the model may call. `spec` is what a provider advertises; `call` validates arguments
  # against the Dry::Schema and hands the coerced hash to the handler with the caller's context.
  # `needs_approval` is a Bool or a callable gate evaluated per invocation.
  class Tool < Dry::Struct
    class Result < Dry::Struct
      attribute :content, Types::Any
      attribute :error, Types::Bool.default(false)
      attribute :metadata, Types::JsonObject.default(Types::EMPTY_HASH)

      class << self
        def success(content:, metadata: Types::EMPTY_HASH) = new(content:, metadata:)
        def failure(content:, metadata: Types::EMPTY_HASH) = new(content:, metadata:, error: true)
      end

      def success? = !error
      def failure? = error
    end

    # A handler returning this leaves its call open: the result lands later, from whatever the
    # call is waiting on, and the run parks instead of terminating.
    PARKED = Object.new.freeze

    EMPTY_SCHEMA = Schema.define

    attribute :description, Types::String
    attribute :handler, Types.Interface(:call)
    attribute :identifier, Types::String.optional.default(nil)
    attribute :input_schema, Types::JsonObject
    attribute :name, Types::String
    attribute :needs_approval, Types::ApprovalGate.default(false)
    attribute :schema, Types.Instance(Dry::Schema::Processor)

    def self.define(
      name,
      legacy_description = nil,
      description: legacy_description,
      identifier: nil,
      schema: EMPTY_SCHEMA,
      requires_approval: nil,
      needs_approval: false,
      &handler
    )
      approval = requires_approval.nil? ? needs_approval : requires_approval
      new(name:, description:, identifier:, schema:, input_schema: schema.json_schema,
          needs_approval: approval, handler:)
    end

    def call(arguments, context:)
      handler.call(prepare(arguments), context)
    end

    def approval_required?(arguments, context: nil)
      return needs_approval unless needs_approval.respond_to?(:call)

      needs_approval.call(arguments, context)
    end

    def approval_gated? = needs_approval != false
    def prepare(arguments) = validate(arguments)

    def spec
      { name:, description:, input_schema: }
    end

    private

    def validate(arguments)
      result = schema.call(arguments)
      raise ArgumentError, result.errors.to_h.inspect unless result.success?

      Types::JsonObject[result.to_h]
    end
  end
end
