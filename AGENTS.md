## AimHelm conventions

- Alphabetize unordered constant arrays such as event registries. Preserve semantic order when the
  array's order affects behavior.
- In every `Dry::Struct`, list required and defaulted attributes first, then optional attributes.
  Alphabetize attributes within each group.
- Class and module comments lead with what the constant does, in domain words — omit the comment
  entirely when the name already says it. Add where or how it is used only when that helps the
  reader: a non-obvious entry point, a seam wired from config. One to five lines; terse, but prefer
  a full sentence over a cryptic fragment when the class embodies a decision worth following.
- Keep all other comments for a non-obvious invariant, irregularity, or input/output shape, beside
  the code they explain. Comments must match the code in this file today — no planned behavior, no
  consumer lists that rot as call sites move. Enforce this in every AimHelm review.
