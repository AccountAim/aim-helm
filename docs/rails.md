# Queued Rails applications

AimHelm's Rails adapters are optional. The application keeps ownership of its records, jobs,
authorization, and UI transport.

Configure those boundaries during boot:

```ruby
AimHelm.configure do |config|
  config.session_model = AgentSession
  config.tools = AimHelm::Tools::Resolver.new(namespace: AgentTools)
  config.advance_job = AdvanceSessionJob
  config.advance = AimHelm::ActiveJob.method(:dispatch)
  config.authorize = lambda do |context:, tool:, **|
    ToolPermission.find_by(
      actor: context,
      tool: tool.identifier,
    )&.to_global_id&.to_s
  end
end
```

This wiring gives each boundary one job:

- `session_model` stores the append-only entries, persisted context, and worker lease.
- `tools` resolves durable tool identifiers to the current application handlers.
- `advance_job` selects the Active Job class, while `advance` dispatches it for a session.
- `authorize` returns a stable rule identifier to pre-approve a gated call, or `nil` to require a
  human decision.

The request process uses the same `run` call as an inline script. With a dispatcher configured, the
call records the input, schedules work, and returns `AimHelm::Run::Queued`:

```ruby
session = AimHelm::Session.new(store: AimHelm.config.store)
agent.run("Summarize report rpt_42.", session:)
```

The worker reconstructs the agent definition from the session and advances existing work:

```ruby
class AdvanceSessionJob < ApplicationJob
  def perform(session_id)
    session = AimHelm.session(session_id)
    AimHelm.agent(session:).advance
  end
end
```

Queued workers resolve stored tool identifiers through `config.tools`; handlers are never serialized
into the session log. Extra dispatches are safe when another worker already owns the lease.

Transport and queue backends remain application choices connected at the configuration boundary.
