# frozen_string_literal: true

module AimHelm
  module Tools
    module Agents
      # The model's handles on children already spawned: list, read (optionally waiting), steer,
      # stop, and continue. Everything but list_agents goes through the host, so one tool set
      # serves both the in-process ThreadHost and the durable store host.
      class Control < Dry::Struct
        MAX_READ_TIMEOUT = 300

        READ_SCHEMA = Schema.define do
          required(:id).filled(:string)
          optional(:wait).filled(:bool)
          optional(:timeout).filled(:integer, gteq?: 1, lteq?: MAX_READ_TIMEOUT)
        end

        STEER_SCHEMA = Schema.define do
          required(:id).filled(:string)
          required(:message).filled(:string)
        end

        STOP_SCHEMA = Schema.define do
          required(:id).filled(:string)
        end

        CONTINUE_SCHEMA = Schema.define do
          required(:id).filled(:string)
          required(:task).filled(:string)
        end

        attribute :host, Types.Interface(:read, :queue_message, :stop, :continue)

        def tools = [list_tool, read_tool, steer_tool, stop_tool, continue_tool]

        private

        def list_tool
          Tool.define("list_agents",
                      "List subagents spawned by this session.") do |_arguments, context|
            context.session.subagents.map do
              {
                id: it.id,
                name: it.name,
                task: it.task,
                status: it.status,
              }
            end
          end
        end

        def read_tool
          target = host

          Tool.define("read_agent", "Read a subagent's status and recent transcript.",
                      schema: READ_SCHEMA) do |arguments, context|
            target.read(
              id: arguments.fetch("id"),
              wait: arguments.fetch("wait", false),
              timeout: arguments.fetch("timeout", MAX_READ_TIMEOUT),
              context:,
            )
          end
        end

        def steer_tool
          target = host

          Tool.define("steer_agent", "Add an instruction at a subagent's next turn boundary.",
                      schema: STEER_SCHEMA) do |arguments, context|
            target.queue_message(
              id: arguments.fetch("id"),
              message: arguments.fetch("message"),
              context:,
            )
          end
        end

        def stop_tool
          target = host

          Tool.define("stop_agent", "Ask a subagent to stop at its next safe boundary.",
                      schema: STOP_SCHEMA) do |arguments, context|
            target.stop(id: arguments.fetch("id"), context:)
          end
        end

        def continue_tool
          target = host

          # Like a spawn, a continued background child answers this call when it reports.
          Tool.define("continue_agent", "Continue a finished subagent with a new task.",
                      schema: CONTINUE_SCHEMA) do |arguments, context|
            receipt = target.continue(
              id: arguments.fetch("id"),
              task: arguments.fetch("task"),
              context:,
            )
            receipt.is_a?(Subagents::Receipt) ? Tool::PARKED : receipt
          end
        end
      end
    end
  end
end
