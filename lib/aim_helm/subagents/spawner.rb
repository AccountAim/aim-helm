# frozen_string_literal: true

module AimHelm
  module Subagents
    # Turns one spawn_agent call into the Record a host can run: resolves the named grant or the
    # open grant, derives the child's system prompt, model, tools, and budget from it, and
    # refuses anything the grant does not allow. Bad wiring raises at construction, bad arguments
    # per call.
    class Spawner < Dry::Struct
      attribute :host, Types.Interface(:spawn)
      attribute :models, Types::Array.of(Types::String)
      attribute :options, Types.Instance(AimHelm::Agent)
      attribute :resolver, Types.Interface(:resolve).optional.default(nil)

      def initialize(...)
        super
        validate_configuration!
      end

      def call(arguments, context:)
        host.spawn(record: record_for(arguments, context:), context:)
      end

      private

      def record_for(arguments, context:)
        definition = definition_for(arguments["agent"])
        grant = definition || open_grant
        instructions = arguments["instructions"].to_s.strip

        validate_authorship!(arguments, definition:, grant:, instructions:)

        subagent_options = subagent_options(arguments, definition:, grant:, instructions:)
        mode = arguments.fetch("mode", "inline")
        validate_mode!(grant, mode)
        validate_inline_grant!(subagent_options) if mode == "inline"
        Record.new(
          session_id: SecureRandom.uuid_v7,
          parent_session_id: context.session.id,
          run_id: SecureRandom.uuid_v7,
          parent_run_id: context.run_id,
          call_id: context.call_id,
          name: definition&.name || arguments.fetch("name"),
          task: arguments.fetch("task"),
          mode:,
          options: subagent_options,
        ).tap(&:dump)
      end

      def subagent_options(arguments, definition:, grant:, instructions:)
        Agent::Record.new(
          system: system_for(definition, instructions),
          model: definition&.model || options.model,
          reasoning: definition&.reasoning || options.reasoning,
          tools: selected_tool_names(arguments, grant),
          subagents: nil,
          output_schema: definition&.output_schema&.json_schema,
          max_iterations: definition&.max_iterations || options.max_turns,
          budget: subagent_budget(definition),
          compaction: definition&.compaction || options.compaction,
          reminders: options.reminders,
        )
      end

      def subagent_budget(definition)
        configured = definition&.budget
        return configured unless options.budget

        options.budget.narrow(configured)
      end

      def system_for(definition, instructions)
        [definition&.system, instructions]
          .reject {  it.to_s.strip.empty? }
          .join("\n\n")
      end

      def selected_tool_names(arguments, grant)
        names = arguments.fetch("tools", grant.tools)
        raise ArgumentError, "tool selections cannot contain duplicates" unless names.uniq == names

        names.each do
          raise KeyError, it unless grant.tools.include?(it)

          # fetch raises for a name no tool backs; the rescue below turns it into an ArgumentError.
          fetch_tool(it)
        end

        names
      rescue KeyError => e
        raise ArgumentError, "unknown subagent tool #{e.key.inspect}"
      end

      def definition_for(name)
        return unless name

        definitions.fetch(name)
      rescue KeyError
        raise ArgumentError, "unknown subagent #{name.inspect}"
      end

      def validate_configuration!
        raise ConfigurationError, "subagent model allowlist cannot be empty" if models.empty?

        unless models.uniq == models
          raise ConfigurationError, "subagent model allowlist contains duplicates"
        end

        specialists.each do
          model = it.model || options.model

          unless models.include?(model)
            raise ConfigurationError,
                  "subagent #{it.name.inspect} uses unknown model #{model.inspect}"
          end

          missing = it.tools.reject { available?(it) }
          next if missing.empty?

          message = "subagent #{it.name.inspect} has unavailable tools: " \
                    "#{missing.join(", ")}"
          raise ConfigurationError, message
        end

        return unless open_grant

        missing = open_grant.tools - parent_tool_pool.keys
        return if missing.empty?

        raise ConfigurationError, "open subagent has unavailable tools: #{missing.join(", ")}"
      end

      def validate_inline_grant!(record)
        gated = record.tools.select { fetch_tool(it).approval_gated? }
        return if gated.empty?

        raise ArgumentError,
              "inline subagent tools require no approval gates; use background mode for: " \
              "#{gated.join(", ")}"
      end

      def validate_mode!(grant, mode)
        return if grant.modes.include?(mode.to_sym)

        label = grant.open? ? "open subagent" : "subagent #{grant.name.inspect}"
        raise ArgumentError, "#{label} does not allow #{mode} mode"
      end

      def validate_authorship!(arguments, definition:, grant:, instructions:)
        raise ArgumentError, "dynamic subagents are not enabled" unless grant

        if definition
          if arguments.key?("name") || !instructions.empty?
            raise ArgumentError, "named agents accept only a task and mode"
          end
        elsif arguments["name"].to_s.strip.empty? || instructions.empty?
          raise ArgumentError, "dynamic agents require name and instructions"
        end
      end

      def definitions
        @definitions ||= begin
          items = specialists.to_h do
            [it.name, it]
          end
          expected = specialists.length
          raise ConfigurationError, "subagent names must be unique" unless items.length == expected

          items
        end
      end

      def specialists = @specialists ||= Array(options.subagents).reject(&:open?)

      def open_grant
        grants = Array(options.subagents).select(&:open?)
        raise ConfigurationError, "only one open subagent grant is allowed" if grants.length > 1

        grants.first
      end

      def tool_pool
        @tool_pool ||= available_tools.to_h do
          [it.identifier || it.name, it]
        end
      end

      # A named grant may carry tools the parent does not hold: a rebuilt run record drops the
      # grant's Agent, so registered identifiers fall back to the durable resolver.
      def fetch_tool(name)
        tool_pool.fetch(name) do
          raise KeyError.new("key not found: #{name.inspect}", key: name) unless resolvable?(name)

          resolver.resolve(name)
        end
      end

      def available?(name) = tool_pool.key?(name) || resolvable?(name)

      def resolvable?(name)
        return false unless resolver

        resolver.resolve(name)
        true
      rescue ConfigurationError
        false
      end

      def parent_tool_pool
        @parent_tool_pool ||= options.tools.to_h do
          [it.identifier || it.name, it]
        end
      end

      # A named grant may carry tools from its own Agent; an open grant stays within the parent's.
      def available_tools
        child_tools = (options.subagents || []).flat_map do
          it.definition&.tools || []
        end
        [*options.tools, *child_tools]
      end
    end
  end
end
