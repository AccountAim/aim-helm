# frozen_string_literal: true

module AimHelm
  module Tools
    # Runs a batch of tool calls on a fixed thread pool. Each call appends a `tool_started` entry
    # first — a duplicate append means it already ran and raises rather than repeat a side
    # effect. Results come back in call order, and the first failure is re-raised, aborting the
    # batch.
    class Executor < Dry::Struct
      include Dry::Monads[:result, :task]

      MAX_CONCURRENCY = 5

      attribute :app, Types.Instance(Object).optional.default(nil)
      attribute :emit, Types.Interface(:call)
      attribute :max_concurrency,
                Types::Coercible::Integer.constrained(gt: 0).default(MAX_CONCURRENCY)
      attribute :run_id, Types::String
      attribute :session, Types.Instance(AimHelm::Session)
      attribute :tools, Types::Array.of(Types.Instance(AimHelm::Tool))
      attribute :turn_id, Types::String

      def prepare(tool_call)
        tool = lookup(tool_call.fetch("name"))
        arguments = tool.prepare(tool_call.fetch("arguments"))
        PreparedCall.new(source: tool_call, tool:, arguments:)
      end

      def call(tool_calls)
        scheduled = tool_calls.map { [it, schedule(it)] }

        scheduled.map do |tool_call, task|
          case task.to_result
          in Success(Tool::PARKED) then { call_id: tool_call.fetch("id"), parked: true }
          in Success(output) then result(tool_call, output, error: false)
          in Failure(error) then raise error
          end
        end
      end

      def shutdown
        @pool&.shutdown
        @pool&.wait_for_termination(5)
      end

      private

      def schedule(tool_call)
        Task[pool] { run(tool_call) }
      end

      def run(tool_call)
        prepared = prepare(tool_call)
        append_start(prepared)
        emit.call(Event.build(type: :"tool.started", call_id: prepared.call_id,
                              name: prepared.name, arguments: prepared.arguments))
        execute(prepared)
      rescue ArgumentError => e
        # Schema validation raises ArgumentError: the model's to repair, not a run-killer.
        emit.call(Event.build(type: :"tool.failed", call_id: tool_call.fetch("id"),
                              error: e.message))
        Tool::Result.failure(content: "Invalid arguments: #{e.message}")
      rescue StandardError => e
        emit.call(Event.build(type: :"tool.failed", call_id: tool_call.fetch("id"),
                              error: e.message))
        raise
      end

      def execute(prepared)
        call_id = prepared.call_id
        context = Context.new(
          session:,
          events: Broadcaster.new(sink: emit, call_id:),
          app:,
          run_id:,
          turn_id:,
          call_id:,
        )

        prepared.tool.call(prepared.arguments, context:).tap do
          # A parked call has not completed; it keeps its started state until its result lands.
          next if it.equal?(Tool::PARKED)

          # Handlers may return a raw value instead of a Tool::Result; only a Result can fail.
          if it.respond_to?(:failure?) && it.failure?
            emit.call(Event.build(type: :"tool.failed", call_id:, name: prepared.name,
                                  error: [it.content].flatten.grep(String).join(" ")))
          else
            emit.call(Event.build(type: :"tool.completed", call_id:, name: prepared.name))
          end
        end
      end

      def append_start(prepared)
        entry = session.append(
          :tool_started,
          { call_id: prepared.call_id },
          key: "started:#{prepared.call_id}",
          run_id:,
          turn_id:,
        )
        return entry if entry

        raise AppendAnomaly, "duplicate tool execution for session #{session.id}"
      end

      def lookup(name)
        tools.find { it.name == name } || raise(KeyError, "unknown tool #{name.inspect}")
      end

      def result(tool_call, output, error:)
        if output.is_a?(Tool::Result)
          error = output.failure?
          metadata = output.metadata
          output = output.content
        end

        {
          call_id: tool_call.fetch("id"),
          output: serialize(output),
          error:,
          metadata:,
        }.compact
      end

      # An Array is content blocks (String, Image, block Hash) kept structured, so replay hands
      # the provider typed blocks instead of a JSON string the model would read as text.
      def serialize(output)
        case output
        when String then output
        when Array then Types::ContentBlocks[output]
        else JSON.generate(output)
        end
      end

      def pool = @pool ||= Concurrent::FixedThreadPool.new(max_concurrency)
    end
  end
end
