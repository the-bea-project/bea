# Changelog

All notable changes to Bea are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Bea uses
[semantic versioning](https://semver.org/).

## [0.3.0] - 2026-10-24

### Added

- **Records.** A type with a single constructor named like the type can list
  its fields in braces:

  ```bea
  pub type AuthToken { sub: String, role: String }

  pub type Page(item) {
    items: List(item),
    total: Int,
  }
  ```

  Each is exactly `pub type AuthToken { AuthToken(sub: String, role: String) }`:
  the generated Gleam, `@derive`, functions through the type
  (`AuthToken.decoder()`), construction, patterns and record updates are the
  same as for the long form. Generic records declare their parameters as
  usual, so the order of `Page(Int)` never depends on the order of the
  fields. A body starting with `name:` holds a record's fields, one starting
  with an uppercase name lists constructors; the long form keeps working
  unchanged, and the formatter keeps whichever form, and layout, you wrote.
- **`bea pack`** packages the project into a single standalone executable
  with [gleepack](https://github.com/yoshi-monster/gleepack): the compiled
  project, its dependencies and an Erlang runtime in one file that runs on
  machines without Erlang. `-o/--output`, `-m/--module` and repeatable
  `-t/--target` (one executable per gleepack target), or `[tools.gleepack]`
  in `bea.toml`. gleepack is found on the PATH, in `BEA_GLEEPACK`, or as a dev
  dependency of the project. Erlang target only.
- **`bea test`** runs the project's tests: `test/<package>_test.gleam`'s
  `main` (gleeunit or any other runner), built like the rest of the project
  and run from the project root, so tests read files relative to it. It takes
  `bea run`'s options (`--target`, ...), and arguments go to the tests.
- **Bea is written in Bea.** The compiler, formatter, language server and
  CLI are now Bea code (`src/**/*.bea`), and the repository is an ordinary
  Bea project: `bea build`, `bea test` and `bea pack` build, test and package
  the compiler itself. The `bea` binary on the releases page is built that
  way.

### Changed

- Gleam test modules in `test/` are compiled with the project by
  `bea build` and `bea check`, as `gleam build` does with a Gleam project's
  tests (before, `test/` was ignored).
- Clearer diagnostics for record-like declarations Bea doesn't take:
  `type Point(x: Float)` says the fields go in braces, `type UserId(Int)`
  shows the long form for a wrapper, and malformed records point at the
  field (a missing label, a constructor among the fields, a missing comma).

### Fixed

- A constructor pattern spanning several lines with Gleam's spread and the
  trailing comma Gleam's formatter writes (`Ctor(\n  a:,\n  ..,\n)`) is
  accepted, and means the same as without the comma.

### For contributors

- The repository is a Bea project: `bea.toml`, the compiler in `src/*.bea`,
  Gleam tests in `test/`. Build with an installed `bea` (`bea build`), then
  let the new compiler rebuild and test itself (`scripts/bea build`,
  `scripts/bea test`); `bea pack` builds the `bea` binary. Building from
  source therefore needs a `bea` (a release, or one you built before), or
  the last all-Gleam revision, which builds with Gleam alone; see
  docs/self-hosting.md.
- The migration from Gleam is recorded there and in the history: every
  module was translated mechanically and checked to be the same program as
  its Gleam original, and a trusted bootstrap required the Gleam-built and
  the Bea-built compilers to generate identical code.

## [0.2.0]

The version before this changelog was started.

[0.3.0]: https://github.com/the-bea-project/bea/compare/417b591...v0.3.0
[0.2.0]: https://github.com/the-bea-project/bea/tree/417b591
