# frozen_string_literal: true

module AimHelm
  # Drives one run through as many provider turns as it needs. A provider turn and its tool work
  # share one turn_id; a subsequent provider invocation gets another. Every durable entry keeps
  # the run_id, while entries within a provider turn also keep its turn_id so approval resumes can
  # restore the same rendering context.
  class Runner < Dry::Struct
    include Dry::Monads[:result]
    include Transcript
    include Accounting

    RUN_ID = Types::String.default { SecureRandom.uuid_v7 }
    TURN_ID = Types::String.default { SecureRandom.uuid_v7 }

    attribute :app, Types.Instance(Object).optional.default(nil)
    attribute(:authorize, Types.Interface(:call).default { Tools::Batch::NO_AUTHORIZATION })
    attribute :budget, Types.Instance(AimHelm::Budget).optional.default(nil)
    attribute :compactor, Types.Interface(:call).optional.default(nil)
    attribute(:config, Types.Instance(AimHelm::Config).default { AimHelm.config })
    attribute :emit, Types.Interface(:call).optional.default(nil)
    attribute :max_iterations, Types::Coercible::Integer.constrained(gt: 0).default(20)
    attribute :model, Types::String.optional.default(nil)
    attribute(:on_interrupted_tool,
              Types.Interface(:call).default { Tools::Batch::NO_INTERRUPTED_TOOL_HANDLER })
    attribute :options, Types.Instance(AimHelm::Agent).optional.default(nil)
    attribute :prompt, Types::ContentBlocks.optional.default(nil)
    attribute :provider, Types.Interface(:stream, :close).optional.default(nil)
    attribute :publisher, Types.Interface(:call).optional.default(nil)
    attribute :request_builder, Types.Interface(:call).optional.default(nil)
    attribute :run_id, RUN_ID
    attribute :session, Types.Instance(AimHelm::Session)
    attribute :tool_runner, Types.Interface(:start, :resume, :close).optional.default(nil)

    class << self
      def call(prompt:, session:, options: nil, config: session.config, **)
        new(
          prompt:,
          session:,
          options:,
          config:,
          model: options&.model,
          max_iterations: options&.max_turns || 20,
          budget: options&.budget,
          **,
        ).call
      end

      def resume(run_id:, session:, options: nil, config: session.config, **)
        new(
          run_id:,
          session:,
          options:,
          config:,
          model: options&.model,
          max_iterations: options&.max_turns || 20,
          budget: options&.budget,
          **,
        ).resume
      end
    end

    def call
      execute do
        load_entries
        append_user
        restore
        iteration_loop
      end
    end

    def run(prompt: self.prompt) = new(prompt:).call

    def resume
      execute do
        load_entries
        next Failure([:cancelled, nil]) if stop_requested?

        if (tool_turn = latest_tool_turn)
          @turn_id = tool_turn.turn_id or raise ProtocolError,
                                                "tool turn #{tool_turn.id} has no turn_id"
          outcome = tools_runtime.resume(
            entries: transcript,
            session:,
            run_id:,
            turn_id: @turn_id,
            events: method(:publish_in_turn),
            app:,
          )
          refresh_entries
          next Success(outcome) if outcome.open?
        end

        restore
        completed = completed_assistant
        next completed if completed

        iteration_loop
      end
    end

    private

    def execute
      finish(yield)
    rescue TransientError
      # A transient failure leaves the turn open for the retry; other errors terminate it.
      raise
    rescue StandardError => e
      append_terminal(:failed, reason: :exception, error: e.message) unless @terminal_attempted
      publish(Event.build(type: :"run.failed", reason: :exception, error: e.message))
      raise
    ensure
      cleanup
    end

    def iteration_loop
      max_iterations.times do
        case run_iteration
        in Success(:continue) then next
        in Success => result then return result
        in Failure => failure then return failure
        end
      end

      Failure([:max_iterations, "reached #{max_iterations} iterations"])
    end

    def run_iteration
      refresh_entries
      return Failure([:cancelled, nil]) if stop_requested?

      reload_messages if fold_messages
      failure = budget_failure
      return failure if failure

      message = stream_message
      append_assistant(message)
      @messages << message
      refresh_entries

      return Failure([:cancelled, nil]) if stop_requested?

      failure = budget_failure
      return failure if failure

      return run_tools(message.tool_calls) if message.tool_calls.any?

      if fold_messages
        reload_messages
        return Success(:continue)
      end

      if message.stop_reason == :stop
        case validate_output(message)
        in Success(output)
          @validated_output = output
          return Success(message)
        in Failure(detail)
          if retry_output?
            append_output_correction(detail)
            return Success(:continue)
          end

          return Failure([:invalid_output, detail])
        end
      end

      Failure([message.stop_reason, message.text])
    rescue TransientError
      raise
    rescue ProviderError => e
      Failure([:provider_error, e.message])
    end

    def stream_message
      @turn_id = TURN_ID[]
      publish_in_turn(Event.build(type: :"turn.started"))

      provider_client.stream(**request.call(entries: transcript)) do
        publish_in_turn(it)
      end
    end

    def run_tools(tool_calls)
      outcome = tools_runtime.start(
        calls: tool_calls,
        entries: transcript,
        session:,
        run_id:,
        turn_id: @turn_id,
        events: method(:publish_in_turn),
        app:,
      )
      refresh_entries
      return Success(outcome) if outcome.open?

      reload_messages
      Success(:continue)
    end

    def append_user
      message = Message.user(prompt)
      append!(:user, { content: message.content })
    end

    def restore
      fold_messages
      reload_messages
      publish(Event.build(type: :"run.started"))
    end

    def append_assistant(message)
      append!(
        :assistant,
        {
          content: message.content,
          model: message.model,
          provider: message.provider,
          stop_reason: message.stop_reason,
          usage: usage_payload(message),
        },
        turn_id: @turn_id,
      )
    end

    def finish(result)
      case result
      in Success(Tools::Batch::Outcome => outcome)
        # A run parked on an approval or a delegated child writes no terminal: it resumes where
        # it stopped once the call it is waiting on gets its result.
        Success(
          Result.new(
            session:,
            run_id:,
            status: outcome.awaiting_approval? ? :awaiting_approval : :awaiting_subagent,
            pending: outcome.pending,
          ),
        )
      in Success(message)
        append_terminal(:done)
        publish(Event.build(type: :"run.completed"))
        compact
        Success(Result.new(session:, message:, output: @validated_output, run_id:))
      in Failure(:cancelled, detail)
        append_terminal(:stopped, reason: :cancelled)
        publish(Event.build(type: :"run.stopped", reason: :cancelled))
        Failure([:cancelled, detail])
      in Failure(reason, detail)
        append_terminal(:failed, reason:, error: detail)
        publish(Event.build(type: :"run.failed", reason:))
        result
      end
    end

    def append_terminal(outcome, reason: nil, error: nil)
      @terminal_attempted = true
      payload = { outcome:, reason:, error: }.compact
      append!(:terminal, payload, key: "terminal:#{run_id}")
    end

    def append!(kind, payload, key: nil, turn_id: nil)
      remember(session.append!(kind, payload, key:, run_id:, turn_id:))
    end

    def publish(event)
      event_publisher.call(event.with(session_id: session.id, run_id:))
    end

    def publish_in_turn(event)
      publish(event.with(turn_id: @turn_id))
    end

    def latest_tool_turn
      transcript.reverse_each.find do
        it.run_id == run_id && it.kind == "tool_call"
      end
    end

    def event_publisher
      @event_publisher ||= publisher || Events::Publisher.new(sink: emit)
    end

    def provider_client
      @provider_client ||= provider || Providers.resolve(
        options.model,
        config:,
        reasoning: options.reasoning,
      )
    end

    def request
      @request ||= request_builder || Request.new(
        system: options.instructions,
        tools: options.tools,
        reminders: options.reminders,
        output_schema: options.output,
      )
    end

    def tools_runtime
      @tools_runtime ||= tool_runner || Tools::Runner.new(
        tools: options.tools,
        authorize:,
        on_interrupted_tool:,
      )
    end

    def validate_output(message)
      return Success(nil) unless options.output

      value = JSON.parse(message.text)
      schema = options.output
      return Success(value) unless schema.respond_to?(:call)

      result = schema.call(value)
      return Success(result.to_h) if result.success?

      Failure(result.errors.to_h.inspect)
    rescue JSON::ParserError => e
      Failure(e.message)
    end

    def retry_output?
      @output_attempts = @output_attempts.to_i + 1
      @output_attempts <= options.output_retries
    end

    def append_output_correction(detail)
      message = Message.user(
        "The previous output did not match the required schema: #{detail}. Return corrected JSON.",
      )
      append!(:user, { content: message.content })
      reload_messages
    end

    def cleanup
      @tools_runtime&.close
      @provider_client&.close
      @event_publisher&.close
    rescue StandardError => e
      config.logger.error("AimHelm cleanup failed: #{e.message}")
    end
  end
end
