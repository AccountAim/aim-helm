# AimHelm

AimHelm is a Ruby library for AI agents whose work must survive requests, jobs, retries, and
process restarts. It supports OpenAI and Anthropic behind one API and stores each session as an
append-only log owned by the application.

AimHelm is under heavy development. Interfaces may change without notice until the 1.0 release.

The project is inspired by [Mistri](https://github.com/mcheemaa/mistri).

## Installation

Add the gem from GitHub:

```ruby
gem "aim-helm", github: "accountaim/aim-helm"
```

Bundler loads the gem through `aim-helm`; its Ruby namespace is `AimHelm`.

AimHelm requires Ruby 3.4 or newer. The core has no Rails dependency. Active Record and Active Job
adapters load when those frameworks are available.

## Getting started

Create an agent and run it:

```ruby
agent = AimHelm.agent(
  "gpt-6-luna",
  instructions: "Answer clearly and accurately.",
)

run = agent.run!("Explain append-only logs in two sentences.") do |event|
  print event.delta if event.type == :"message.delta"
end

puts run.text
```

Without an explicit session, AimHelm creates an in-memory session and returns it on the run. Pass
that session back to continue the conversation:

```ruby
first = agent.run("Remember the codeword cedar-17.")
second = agent.run("What was the codeword?", session: first.session)

puts second.text
```

`run!` returns a completed run or raises `AimHelm::IncompleteRun`. Use `run` when queuing,
approval, delegation, stopping, or failure are ordinary application states:

```ruby
case run = agent.run("Investigate the failed deployment.")
when AimHelm::Run::Completed
  puts run.text
when AimHelm::Run::AwaitingApproval
  notify_reviewers(run.pending_approvals)
when AimHelm::Run::Queued, AimHelm::Run::AwaitingSubagent
  puts "Work will continue asynchronously."
when AimHelm::Run::Stopped, AimHelm::Run::Failed
  warn "#{run.reason}: #{run.detail}"
end
```

## Durable sessions

An agent is an immutable definition. A session folds its append-only log into the current state of
one conversation. Inspecting it is side-effect free:

- `status` reports where work is now, such as `:queued`, `:awaiting_approval`, or `:completed`.
- `transcript` returns the serialized log entries for audit, display, or debugging.
- `pending_approvals` returns the unresolved tool calls a person can approve or deny.
- `subagents` returns handles for inspecting, messaging, or stopping child sessions.
- `spend` totals token usage, provider cost, and wall-clock time recorded in the log.

The JSONL store is useful for scripts and local tools:

```ruby
store = AimHelm::Stores::JSONL.new(dir: "tmp/aim_helm-sessions")
session = AimHelm::Session.new(store:)

agent.run!("Remember the codeword cedar-17.", session:)

session = AimHelm::Session.new(store:, id: session.id)
run = agent.run!("What was the codeword?", session:)

puts run.text # answers from the history loaded out of the JSONL file
```

Production stores implement `append`, `entries`, and `transaction`. Keyed appends and database
uniqueness make terminal results, tool results, and approval decisions idempotent.

## Guides

- [Tools and approval](docs/tools-and-approvals.md)
- [Queued Rails applications](docs/rails.md)
- [Subagents](docs/subagents.md)
- [Deterministic testing](docs/testing.md)

AimHelm also supports structured output, image input, budgets, compaction, reminders, normalized
streaming events, and process-wide broadcasting.

## Development

The repository includes a Dockerfile and `justfile`:

```sh
just spec             # deterministic test suite
just rubocop          # style and custom project conventions
just live-openai      # real OpenAI streaming and tool calls
just live-anthropic   # real Anthropic streaming and tool calls
```

Live tests require `AIM_HELM_LIVE=1` and provider credentials.

## License

AimHelm is available under the [MIT License](LICENSE).
