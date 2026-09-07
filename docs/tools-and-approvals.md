# Tools and approval

Tool schemas validate provider input before application code runs:

```ruby
lookup_report = AimHelm::Tool.define(
  "lookup_report",
  description: "Loads a report by ID.",
  identifier: "reports/lookup",
  schema: AimHelm::Schema.define {
    required(:report_id).filled(:string)
  },
) do |arguments, context|
  report = Reports.fetch(arguments.fetch("report_id"))
  context.broadcast(:"report.loaded", report_id: report.id)
  { report_id: report.id, status: report.status }
end
```

Schemas coerce values and remove undeclared keys. Handlers receive string-keyed arguments and a
context containing application state, session and run IDs, a stable idempotency key, and `broadcast`.
`context.app` holds the application context passed to `agent.run(context:)`.

Return ordinary JSON-compatible content on success. `AimHelm::Tool::Result` can attach host-only
metadata or report an expected failure that the model may act on.

## Human approval

Use `needs_approval:` when a tool may require a decision:

```ruby
publish = AimHelm::Tool.define(
  "publish",
  description: "Publishes a message externally.",
  needs_approval: true,
  schema: AimHelm::Schema.define {
    required(:message).filled(:string)
  },
) do |arguments, _context|
  Publisher.publish(arguments.fetch("message"))
end
```

The run parks before the handler executes. A later request or process can approve or deny the call:

```ruby
approval = session.pending_approvals.first
session.approve(approval.call_id, by: "user:42", note: "Reviewed")

# Or reject it:
session.deny(approval.call_id, by: "user:42", reason: "Not ready")
```

When a dispatcher is configured, either decision wakes the session automatically. Without one,
resume the parked run explicitly:

```ruby
run = agent.run(session:)
```

Approval requests and decisions are append-only. Before running an approved handler, AimHelm
resolves the tool again, revalidates its arguments, and re-evaluates its approval gate.
