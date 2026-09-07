# frozen_string_literal: true

module AimHelm
  # Routes one piece of agent work. `run` records new input, then queues it onto the session's
  # live runner, dispatches through `config.advance` (returning Run::Queued), or executes here.
  # `advance` executes without appending: a store that leases (`bind`) hands the run to Driver,
  # and a refused lease reports Run::Queued because another process owns the session. Both
  # return a AimHelm::Run variant. Entered only through Agent#run and #advance.
  class Execution < Dry::Struct
    attribute :app, Types.Instance(Object).optional.default(nil)
    attribute :claimed_by, Types::String.optional.default(nil)
    attribute :emit, Types.Interface(:call).optional.default(nil)
    attribute :final_attempt, Types::Bool.default(false)
    attribute :options, Types.Instance(AimHelm::Agent)
    attribute :session, Types.Instance(AimHelm::Session)

    def run(input)
      if input && session.pending_run_id
        Control.new(session:).queue_message(content: input)
        return dispatch_or_observe
      end

      if session.config.advance && options.advance_mode != :inline
        run_id = prepare(input)
        session.config.advance.call(session.id)
        publish(Event.build(type: :"run.queued").with(session_id: session.id, run_id:))
        return Run::Queued.new(id: run_id, session:)
      end

      if bindable?
        prepare(input)
        return advance
      end

      execute(prompt: input)
    end

    def advance
      return execute(prompt: nil) unless bindable?

      binding = session.store.bind(
        session:,
        claimed_by: claimed_by || "inline:#{SecureRandom.uuid_v7}",
        final_attempt:,
        config: session.config,
      )
      return queued_run unless binding

      outcome = Driver.new(options:, binding:, foreground: emit).call
      return queued_run unless outcome

      Run.from(outcome, session:, id: latest_run_id(session))
    end

    private

    def execute(prompt:)
      config = session.config
      runtime_session = session.new(config:)
      attributes = { app:, emit: subscribers(runtime_session) }.compact
      attributes[:provider] = options.provider if options.provider

      outcome, result_session = if options.subagents?
                                  run_with_subagents(
                                    prompt:,
                                    session: runtime_session,
                                    config:,
                                    attributes:,
                                  )
                                else
                                  outcome = run_runner(
                                    prompt:,
                                    session: runtime_session,
                                    config:,
                                    attributes:,
                                  )
                                  [outcome, runtime_session]
                                end

      Run.from(
        outcome,
        session: result_session,
        id: result_session.pending_run_id || latest_run_id(result_session),
      )
    end

    # A configured host outlives this call; an ad-hoc ThreadHost is owned and closed here.
    def run_with_subagents(prompt:, session:, config:, attributes:)
      configured_host = config.subagent_host
      host = configured_host || Subagents::ThreadHost.new(options:, events: emit)
      config = config.with(
        subagent_host: host,
        advance: config.advance || host.method(:advance),
      )
      session = session.new(config:)

      if configured_host
        return [run_runner(prompt:, session:, config:, attributes:, host:), session]
      end

      begin
        outcome = host.owning(session:, app:) do
          run_runner(prompt:, session:, config:, attributes:, host:)
        end
        [outcome, session]
      ensure
        host.close
      end
    end

    def run_runner(prompt:, session:, config:, attributes:, host: nil)
      run_id = Execution::Start.new(options:, session:).prepare(prompt:)
      runtime_options = if options.subagents?
                          Subagents.install(options, host:, models: config.model_catalog.keys,
                                                     resolver: config.tools)
                        else
                          options
                        end
      Runner.resume(
        **attributes,
        config:,
        options: runtime_options,
        session:,
        run_id:,
      )
    end

    # Input landed on a busy session: surface an approval park, dispatch if configured, report a
    # live runner as queued, and only advance inline when nothing else can run the run.
    def dispatch_or_observe
      status = session.status
      return awaiting_run if status == :awaiting_approval

      if session.config.advance
        session.config.advance.call(session.id)
        return queued_run
      end

      return queued_run if status == :running

      advance
    end

    def queued_run
      run_id = session.pending_run_id || latest_run_id(session)
      Run::Queued.new(id: run_id, session:)
    end

    def awaiting_run
      run_id = session.pending_run_id
      Run::AwaitingApproval.new(
        id: run_id,
        session:,
        pending_approvals: session.open_approvals(run_id:),
      )
    end

    def prepare(input) = Execution::Start.new(options:, session:).prepare(prompt: input)
    def bindable? = session.store.respond_to?(:bind)

    def publish(event)
      sink = subscribers(session)
      return event unless sink

      publisher = Events::Publisher.new(sink:)
      publisher.call(event)
      event
    ensure
      publisher&.close
    end

    def subscribers(runtime_session)
      value = Events::Subscribers.new(
        session: runtime_session,
        context: app,
        foreground: emit,
        broadcast: runtime_session.config.broadcast,
      )
      value if value.active?
    end

    def latest_run_id(result_session)
      result_session.entries.reverse_each.find(&:run_id)&.run_id || raise(
        ConfigurationError,
        "session has no run",
      )
    end
  end
end
