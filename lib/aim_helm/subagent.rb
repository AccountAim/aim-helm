# frozen_string_literal: true

module AimHelm
  # A grant declaring what a parent may spawn: a named specialist (built directly or derived from
  # a full Agent via `new(agent:)`), or `Subagent.open`, which lets the model author a child from
  # a tool allowlist. `modes` limits the grant to inline runs, background runs, or both.
  class Subagent < Dry::Struct
    CONTRACT = Schema.define do
      optional(:name).maybe(:string)
      optional(:description).maybe(:string)
      optional(:system).maybe(:string)
      optional(:model).maybe(:string)
      optional(:reasoning).maybe(:string)
      required(:tools).array(:string)
      optional(:output_schema).maybe(:hash)
      optional(:max_iterations).maybe(:integer)
      optional(:budget).maybe(:hash)
      optional(:compaction).maybe(:hash)
      optional(:modes).array(:string)
      optional(:open).filled(:bool)
    end

    extend ClosedRecord

    attribute :budget, Types.Instance(AimHelm::Budget).optional.default(nil)
    attribute :compaction, Types.Instance(AimHelm::Compaction).optional.default(nil)
    attribute :definition, Types.Instance(AimHelm::Agent).optional.default(nil)
    attribute :description, Types::String.optional.default(nil)
    attribute :max_iterations, Types::Coercible::Integer.optional.default(nil)
    attribute :model, Types::String.optional.default(nil)
    attribute :modes,
              Types::Array.of(Types::Coercible::Symbol.enum(:inline, :background))
                          .default(%i[inline background].freeze)
    attribute :name, Types::String.optional.default(nil)
    attribute :open, Types::Bool.default(false)
    attribute :output_schema, Types::OutputSchema.optional.default(nil)
    attribute :reasoning, Types::Coercible::Symbol.optional.default(nil)
    attribute :system, Types::String.optional.default(nil)
    attribute :tools, Types::Array.of(Types::String).default([].freeze)

    class << self
      def new(attributes = nil, **keywords)
        values = attributes ? attributes.merge(keywords) : keywords
        return super(values) unless values.key?(:agent)

        agent = values.fetch(:agent)
        modes = values.fetch(:modes, %i[inline background])
        raise ArgumentError, "subagent agent requires a name" unless agent.name
        raise ArgumentError, "subagent agent requires a description" unless agent.description

        super(
          name: agent.name,
          description: agent.description,
          system: agent.instructions,
          model: agent.model,
          reasoning: agent.reasoning,
          tools: tool_identifiers(agent.tools),
          output_schema: agent.output,
          max_iterations: agent.max_turns,
          budget: agent.budget,
          compaction: agent.compaction,
          modes:,
          open: false,
          definition: agent,
        )
      end

      def open(tools:, modes: %i[inline background])
        new(tools: tool_identifiers(tools), modes:, open: true)
      end

      private

      def tool_identifiers(tools)
        tools.map do
          it.identifier || raise(
            ConfigurationError,
            "subagent tools require registered identifiers",
          )
        end
      end

      def deserialize_attributes(attributes)
        if attributes[:output_schema]
          attributes[:output_schema] = Schema::Serialized.new(
            json_schema: attributes[:output_schema],
          )
        end

        attributes[:budget] = Budget.deserialize(attributes[:budget]) if attributes[:budget]

        if attributes[:compaction]
          attributes[:compaction] = Compaction.deserialize(attributes[:compaction])
        end

        attributes
      end

      def record_label = "subagent definition"
    end

    def open? = open

    def dump
      Types::JsonObject[
        to_h.except(:definition).merge(
          output_schema: output_schema&.json_schema,
          budget: budget&.dump,
          compaction: compaction&.dump,
        ),
      ]
    end
  end
end
