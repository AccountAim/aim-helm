# frozen_string_literal: true

module AimHelm
  # Adds the host-backed spawn_agent and control tools to an Agent that declares subagents, and
  # returns it untouched otherwise. Every path that resumes a turn installs them again: they
  # close over the live host, so they never enter the Agent::Record written to the log.
  module Subagents
    module_function

    def install(options, host:, models:, resolver: nil)
      return options unless options.subagents?

      raise ConfigurationError, "subagent sessions require a host" unless host

      spawner = Spawner.new(options:, host:, models:, resolver:)
      spawn_tools = Tools::Agents::Spawn.new(options:, spawner:, models:).tools
      control_tools = Tools::Agents::Control.new(host:).tools
      options.new(tools: [*options.tools, *spawn_tools, *control_tools])
    end
  end
end
