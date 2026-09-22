# Subagents

Grant an agent a named specialist and the modes in which it may run:

```ruby
auditor = AimHelm.agent(
  "gpt-6-luna",
  name: "ledger_auditor",
  description: "Checks ledger arithmetic and reports discrepancies.",
  instructions: "Audit the ledger and show every calculation.",
  tools: [read_ledger],
)

coordinator = AimHelm.agent(
  "gpt-6-sol",
  instructions: "Delegate ledger checks to the auditor.",
  subagents: [
    AimHelm::Subagent.new(agent: auditor, modes: %i[inline background]),
  ],
)
```

Passing `subagents:` installs AimHelm's spawn and control tools. The model can use only the agents,
modes, and tools granted by the parent definition.

Children are ordinary sessions linked through the parent's append-only log:

```ruby
child = run.session.subagents.find { |candidate| candidate.name == "ledger_auditor" }
```

The handle exposes both inspection and control:

- `status` reports the child's current session state.
- `transcript` returns its serialized append-only log for audit or display.
- `report` returns `nil` until the child finishes, then provides its terminal status, text, and
  error.
- `run("Also check Q3 invoices.")` queues or runs a follow-up turn on the same child session.
- `stop(reason: "No longer needed")` records a stop request for its active work.

Background children continue independently after the parent run completes. If a child later needs
approval, record the decision on the child session. Its terminal report will dispatch the parent
when the host is configured for queued work.

Dynamic agents are available through `AimHelm::Subagent.open`. Their name and instructions are
model-authored for one spawn, while their tools remain a subset of the parent's allowlist.
