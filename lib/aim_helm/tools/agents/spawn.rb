# frozen_string_literal: true

module AimHelm
  module Tools
    module Agents
      # Builds the spawn_agent tool: the description advertises the named grants and the schema
      # confines agent, dynamic fields, tools, and mode to the configured grants.
      class Spawn < Dry::Struct
        DESCRIPTION = <<~TEXT.strip.freeze
          Delegate a focused task to a subagent. Inline subagents run concurrently with sibling tool
          calls and return their report here; background subagents return a receipt immediately.
        TEXT

        attribute :models, Types::Array.of(Types::String)
        attribute :options, Types.Instance(AimHelm::Agent)
        attribute :spawner, Types.Interface(:call)

        def tools
          target = spawner

          [
            # A background child answers this call when it reports, so the call parks and the
            # parent's run stays open rather than taking a receipt and finishing without it.
            Tool.define("spawn_agent", description, schema:) do |arguments, context|
              result = target.call(arguments, context:)
              result.is_a?(Subagents::Receipt) ? Tool::PARKED : result
            end,
          ]
        end

        private

        def description
          definitions = Array(options.subagents).reject(&:open?).map do
            "#{it.name}: #{it.description}"
          end
          dynamic = if Array(options.subagents).any?(&:open?)
                      "Dynamic agents require a name and instructions."
                    end
          [DESCRIPTION, *definitions, dynamic].compact.join("\n")
        end

        def schema
          definitions = Array(options.subagents)
          names = definitions.reject(&:open?).map(&:name)
          open = definitions.any?(&:open?)
          # Union across grants; Spawner enforces the per-grant subset when the call arrives.
          available_tools = definitions.flat_map(&:tools).uniq
          modes = definitions.flat_map(&:modes).map(&:to_s).uniq

          Schema.define do
            required(:agent).filled(:string, included_in?: names) unless open
            required(:task).filled(:string)
            optional(:agent).filled(:string, included_in?: names) if open && names.any?
            optional(:instructions).filled(:string) if open
            optional(:mode).filled(:string, included_in?: modes)
            optional(:name).filled(:string) if open
            optional(:tools).array(:string, included_in?: available_tools) if open
          end
        end
      end
    end
  end
end
