# Deterministic testing

Inject the fake provider to test agent behavior without network requests:

```ruby
provider = AimHelm::Providers::Fake.new(
  model: "gpt-6-luna",
  turns: [
    {
      tool_calls: [
        {
          id: "call_1",
          name: "lookup_report",
          arguments: { report_id: "rpt_42" },
        },
      ],
    },
    { text: "Report rpt_42 is ready." },
  ],
)

agent = AimHelm.agent(
  "gpt-6-luna",
  tools: [lookup_report],
  provider:,
)

run = agent.run!("Check rpt_42.")

expect(run.text).to eq("Report rpt_42 is ready.")
expect(provider.requests.length).to eq(2)
```

Fake turns may return tool calls, text, structured output, usage, or provider errors. For example,
`{ error: "busy", transient: true }` exercises retry behavior without a live provider.
