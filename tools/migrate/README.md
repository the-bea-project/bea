# Migration tooling

How the compiler was moved from Gleam to Bea (docs/self-hosting.md has the
whole story). Nothing here is needed to build or use Bea.

- `gleam_to_bea.py IN.gleam OUT.bea`: translates a Gleam module to Bea. Bea
  reads most Gleam syntax as is, so this works on tokens and keeps the
  module's text, comments and layout; it only rewrites what Bea spells
  differently (`fn` -> `def`, no `let`, `\#{` in strings, line-leading `-`)
  and refuses what it can't translate faithfully (names that are Bea
  keywords, `let assert ... as "message"`).
- `migrate.sh MODULE...`: `git mv`s `compiler/src/MODULE.gleam` to
  `.bea`, translates it and formats it with `bea format`.
- `check.sh`: checks a stage. It runs the bootstrap without installing
  (compilers A, B and C; A and B must generate the same Gleam), then
  compares the trusted seed's Gleam sources with the Gleam that A generated
  from `compiler/src`, using `equiv` (both formatted with `gleam format`
  first, because glance doesn't read everything Gleam accepts).
- `equiv/`: a small Gleam program that parses two source trees with
  [glance](https://hex.pm/packages/glance) and compares them definition by
  definition, ignoring positions, comments and layout, and reading label
  shorthand (`f(x:)`, `Ctor(x:)`, `Ctor(..r, x:)`) and single-expression
  blocks (`{ x }`) as what they stand for. It also reports, separately,
  `let assert` where the original had `let` (none were found).

A stage was: `tools/migrate/migrate.sh <modules>`, `tools/migrate/check.sh`,
`scripts/bootstrap.sh`, the test suites, `scripts/verify_bootstrap.sh`, and
a commit.
