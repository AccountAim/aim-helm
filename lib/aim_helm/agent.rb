# frozen_string_literal: true

module AimHelm
  # Immutable agent definition — instructions, model, tools, budget, turn limits — and the public
  # entry point for running it. `run` takes new input, `advance` continues a session that already
  # holds work, and both hand off to Execution and return a AimHelm::Run. `run!` raises
  # IncompleteRun unless the run completed. Built by AimHelm.agent.
  class Agent < Dry::Struct
    COMPACTION = Types.Instance(AimHelm::Compaction).default { AimHelm::Compaction.new }

    schema schema.strict

    # :inline opts this definition out of config.advance, so #run executes the turn in-process.
    attribute :advance_mode,
              Types::Coercible::Symbol.enum(:inline).optional.default(nil)
    attribute :bound_session, Types.Instance(AimHelm::Session).optional.default(nil)
    attribute :budget, Types.Instance(AimHelm::Budget).optional.default(nil)
    attribute :compaction, COMPACTION
    attribute :description, Types::String.optional.default(nil)
    attribute :instructions, Types::String.default("")
    attribute :max_turns, Types::Coercible::Integer.default(20)
    attribute :model, Types::String
    attribute :name, Types::String.optional.default(nil)
    attribute :output, Types::OutputSchema.optional.default(nil)
    attribute :output_retries, Types::Coercible::Integer.constrained(gteq: 0).default(1)
    attribute :provider, Types.Interface(:stream, :close).optional.default(nil)
    attribute :reasoning, Types::Coercible::Symbol.optional.default(nil)
    attribute :reminders,
              Types::Array.of(Types.Instance(AimHelm::Reminder)).default([].freeze)
    attribute :subagents, Types::Array.of(Types.Instance(Subagent)).optional.default(nil)
    attribute :tools, Types::Array.of(Types.Instance(AimHelm::Tool)).default([].freeze)

    def subagents? = !subagents.nil?
    def with(**changes) = new(**changes)

    def run(input = nil, session: nil, output: nil, context: nil, events: nil, &emit)
      definition = output ? with(output:) : self
      runtime_session = session || bound_session || Session.new(store: Stores::Memory.new)
      sink = emit || events

      Execution.new(
        options: definition,
        session: runtime_session,
        app: context,
        emit: sink,
      ).run(input)
    end

    def run!(...)
      run = run(...)
      return run if run.completed?

      raise IncompleteRun, run
    end

    def advance(
      session: nil,
      claimed_by: nil,
      final_attempt: false,
      context: nil,
      events: nil,
      &emit
    )
      runtime_session = session || bound_session
      raise ConfigurationError, "advance requires a session" unless runtime_session

      Execution.new(
        options: self,
        session: runtime_session,
        claimed_by:,
        final_attempt:,
        app: context,
        emit: emit || events,
      ).advance
    end
  end
end
