# Self-hosting the Bea compiler

Bea transpiles to Gleam, and Bea's compiler is written in Bea. It still
generates Gleam, and it is built by the toolchain it implements:

```text
Bea compiler source (compiler/src/**/*.bea)
          |
          v
Trusted bootstrap compiler (compiler A, the pinned all-Gleam seed)
          |
          v
Generated Gleam (src/**/*.gleam)
          |
          v
Gleam compiler
          |
          v
Executable Bea compiler
```

Gleam stays the backend: its type checker, standard library, runtime and
build tool are used exactly as before. Self-hosting adds no backend, type
checker or runtime, and programs compiled by Bea don't depend on Bea at
run time.

The first part of this document is about building and working on the
compiler. The second part records how the compiler was migrated from Gleam
to Bea: the audit, the plan, and what was verified.

## Source structure

| Path | What it is |
| --- | --- |
| `compiler/src/` | The compiler's sources, authoritative: 34 Bea modules (about 20 900 lines) and the Erlang FFI `bea_ffi.erl` and `bea_signal.erl`. Same module names as before: `bea`, `bea/parser`, `bea/lsp/server`, ... |
| `src/` | Generated from `compiler/src` by `scripts/bootstrap.sh`. Not in git. `src/.bea-generated` lists every file with its hash. |
| `gleam.toml`, `manifest.toml` | The Gleam package `bea` (the compiler), as before. The bootstrap compiles `compiler/src` with this configuration (as the `bea.toml` of a Bea project). |
| `test/` | The Gleam test suite (gleeunit), testing the compiler through its modules. |
| `bootstrap/seed.env` | The trusted seed: the git tree hash of the last all-Gleam revision. |
| `scripts/bootstrap.sh` | Builds the compiler: stages A, B, C, comparison, installation of `src/`. |
| `scripts/verify_bootstrap.sh` | Compares compilers A, B and C on outputs and test suites. |
| `bootstrap/changes-since-seed` | The intended differences between the seed's output and the self-hosted compiler's, one recorded output per line with the reason. |
| `scripts/pack.sh` | Builds the compiler as a standalone executable with gleepack (`build/bea`). |
| `tools/migrate/` | The tooling that did the migration (translator and equivalence checker). Not needed to build. |

No compiler module was kept in Gleam: everything that was a Gleam module is
a Bea module. The two Erlang files were never Gleam and stay Erlang FFI,
bound with `@external` from `bea/system`, `bea/lsp/transport`,
`bea/line_editor`, `bea/shell` and others. Bea compiles a project's
`.gleam` files together with its `.bea` files, so a module could be kept
in Gleam (or written in Gleam later) by putting `x.gleam` in
`compiler/src`; the bootstrap and the tests handle mixed sources.

## How Bea compiles itself

`scripts/bootstrap.sh` runs three stages in `build/bootstrap/`:

- **A, the trusted seed.** `bootstrap/seed.env` pins the last revision of
  the compiler written entirely in Gleam by its git *tree* hash. A tree
  hash names exactly the revision's files and, unlike a commit hash, stays
  the same when commits are rebased or applied with `git am`. The seed is
  extracted with `git archive` (no prebuilt binary, no untracked file) and
  built with `gleam build`. Its provenance is the git history:
  `git log --format='%H %T %s'` shows the commit with that tree, the
  commit before the source layout moved to `compiler/src`.
- **B.** A compiles `compiler/src` as one Bea project (the way `bea build`
  compiles any project: `bea.toml` is the repository's `gleam.toml`, `.bea`
  modules are compiled, `.gleam` and `.erl` files copied), and Gleam
  builds the result with `--warnings-as-errors`.
- **C.** B, the self-hosted compiler, compiles `compiler/src` again, and
  Gleam builds that.

The Gleam that A and B generate from `compiler/src` must be identical,
byte for byte (raw code generation output, not reformatted), or the
bootstrap fails. So B compiles the compiler exactly like the trusted
compiler does, and C is built from exactly the same Gleam as B: compiling
again changes nothing (a fixed point). That Gleam is installed into `src/`
and the repository is built, so `gleam test`, `gleam build` and
`scripts/bea` use the self-hosted compiler.

Installing refuses to overwrite `src/` when it has files tracked by git,
files the bootstrap didn't write, or files edited after the bootstrap
wrote them (their hashes are in `src/.bea-generated`), so generated files
never silently replace a source. Within `compiler/src`, a module present as
both `x.bea` and `x.gleam` is a compile error ("Duplicate module").

`test/bootstrap_test.gleam` checks the same from inside the test suite:
the compiler under test compiles `compiler/src` and must produce exactly
the Gleam it was built from; `src/` must correspond file for file to
`compiler/src` and match its manifest. A stale `src/` fails `gleam test`
with a message saying to run the bootstrap.

## Building from a clean checkout

Prerequisites: git, with the full history (the seed is built from it, so
not a `--depth` clone; `git fetch --unshallow` fixes one), Gleam 1.18,
Erlang/OTP 27 or later (CI uses 28), and access to Hex for the
dependencies the first time. Python 3 and Node.js are only needed for the
language server, CLI and JavaScript tests.

```sh
git clone <repository> bea && cd bea   # full history, no --depth
scripts/bootstrap.sh        # A -> B -> C, installs src/, runs gleam build
gleam test
export PATH=$PWD/scripts:$PATH
scripts/test_examples.sh && scripts/test_tooling.sh && python3 test/lsp/test_lsp.py
scripts/verify_bootstrap.sh # compares A, B and C (outputs and test suites)
```

A full bootstrap takes about a minute; the seed's build is kept between
runs. CI (`.github/workflows/test.yml`) does the same.

`scripts/pack.sh` then builds the compiler as a standalone executable,
`build/bea`, with [gleepack](https://github.com/yoshi-monster/gleepack): it
runs the full bootstrap first and packs exactly that compiler (the `bea`
Gleam package in the repository root, entry point `bea.main`), so the binary
is the verified self-hosted compiler. It needs gleepack on the PATH or in
`BEA_GLEEPACK`.

## Working on the compiler

Edit `compiler/src/**/*.bea`, never `src/`. Then:

```sh
scripts/bootstrap.sh --quick   # compile compiler/src with this checkout's compiler, install, build
gleam test
```

`--quick` uses the compiler you have built instead of going through A, B
and C. When a change affects what the compiler generates for its own
source (code generation, lowering, ...), the first `--quick` build is
compiled by the old compiler; run `--quick` a second time to compile it
with the new one (`bootstrap_test` fails until the result is a fixed
point). Before committing run the full `scripts/bootstrap.sh`, and
`scripts/verify_bootstrap.sh` for a change that could alter behaviour.
Format with `scripts/bea format compiler/src` (CI checks it).

`scripts/verify_bootstrap.sh` compares the seed with the self-hosted
compiler on its whole corpus, so a change in behaviour shows up there as a
difference between A and B, and fails until it is declared: add each
recorded output that changes (a path under `build/bootstrap/verify/A/`, as
the failure lists them) to `bootstrap/changes-since-seed`, with the reason.
A change nobody declared fails, and so does a declaration that no longer
differs, so the file is always the exact list of how the compiler has moved
away from the seed. B and C are always compared without exceptions.

The compiler's source is ordinary Bea: other modules of `compiler/src`
are imported as usual, and so are Gleam packages and Gleam modules placed
in `compiler/src`. It must stay compilable by the seed: the seed is the
compiler from before the migration, so new syntax added to Bea can't be
used in `compiler/src` until the seed moves forward (see below).
Behaviour-preserving changes compared with the seed are visible with
`tools/migrate/check.sh`, which was the migration's check; once the
compiler legitimately changes, differences there are expected.

## Recovering from a broken compiler

The full bootstrap never uses the compiler in your checkout: it always
starts again from the seed. So when `--quick` produced a compiler that
can't compile its own source, or `src/` is broken:

```sh
rm -rf src build/dev       # if src/ itself is in a bad state
scripts/bootstrap.sh       # rebuild from the trusted seed
```

If the bootstrap fails at B ("compiling compiler/src failed"), the Bea
sources don't compile with the seed: the error is a normal Bea diagnostic
in a `compiler/src` file. If it fails at C or at the comparison, the
compiler built from your sources compiles them differently from the seed:
look at `build/bootstrap/B-vs-C.diff`, which is the Gleam the change
affected. Without a working Bea compiler at all, the seed itself is a
complete Gleam project: `git archive $SEED_TREE | tar -x -C /tmp/seed`
(with `SEED_TREE` from `bootstrap/seed.env`), then `gleam build` there and
use `/tmp/seed/scripts/bea`.

`--seed REV` builds compiler A from another all-Gleam revision.

### Moving the seed forward

The seed only needs to compile `compiler/src`. When the compiler's own
source starts using a feature the seed doesn't have, the chain of trust
continues through a revision that the seed can compile and that has the
feature: `scripts/bootstrap.sh --via REV` compiles REV's `compiler/src`
with the seed, uses the result to compile `compiler/src`, and checks B
against C as usual. Once such a revision is required, record it as
`SEED_VIA="REV"` in `bootstrap/seed.env` (a revision whose tree is pinned
the same way, so a tree hash is best): the bootstrap then always goes
seed → REV → B → C.

## Known limitations

- Comments: Bea forwards doc comments (`///`, `////`) to the generated
  Gleam, but not regular `//` comments or doc comments on record fields,
  so `src/` has fewer comments than `compiler/src`. The Bea source keeps
  all of them.
- The compiler's source is a mechanical translation of the Gleam it
  replaced, so it is written in the Gleam-like subset of Bea (`case` rather
  than multi-clause functions and `else` guards, no `?`). That keeps it
  provably the same program; idiomatic rewrites can come later, one
  reviewed change at a time.
- The seed can't compile syntax added to Bea after it (see above).
- The bootstrap needs git history and a POSIX shell with `sha256sum` or
  `shasum`.

---

# Migration record

## 1. Audit (before the migration)

### Build and transpilation pipeline

- The repository root was a Gleam package (`gleam.toml`, `manifest.toml`)
  named `bea`. `src/` held the compiler as 33 Gleam modules (about 21 000
  lines) and two Erlang FFI files; `test/` holds the gleeunit suite.
- `gleam build` produced the compiler; `scripts/bea` runs it from
  `build/dev/erlang/*/ebin` (`bea:main/0`, `src/bea.gleam`).
- For a Bea project, `bea/project.sync` mirrors `bea.toml` into
  `.beabuild/gleam.toml`, compiles every `src/**/*.bea` to
  `.beabuild/src/**/*.gleam` and copies every other source file (`.gleam`,
  `.erl`, `.mjs`, ...) unchanged, so Bea and Gleam modules can import each
  other. A module present as both `x.bea` and `x.gleam` is a "Duplicate
  module" error. `bea transpile --out DIR` writes that generated project out
  as a plain Gleam project (and runs `gleam format` on it).
- Compiling one module (`bea/compiler`): `parser` (which uses `lexer`) →
  `deriving` (`@derive`) → `associated` (`Type.name`) → `lower` → `codegen`
  (printing through `doc`, positions through `sourcemap`).
- CI (`.github/workflows/test.yml`) ran `gleam format --check`,
  `gleam test`, then `scripts/test_examples.sh`, `scripts/test_tooling.sh`
  and `test/lsp/test_lsp.py` through the `bea` launcher.

### Modules

Layers are by import depth (a module only imports modules of lower layers;
Gleam forbids import cycles, so there are no circular dependencies).

| Layer | Modules (lines) | Role |
| --- | --- | --- |
| 0 | `span` (169), `style` (68), `system` (111), `line_editor` (277), `lsp/json` (385), `lsp/text` (114) | Spans and line index, CLI colours, OS access (FFI), shell line editor, JSON, text utilities |
| 1 | `ast` (383), `diagnostic` (146), `doc` (285), `lsp/position` (127), `lsp/transport` (69) | Syntax tree, diagnostics, pretty printer, LSP positions, JSON-RPC framing |
| 2 | `lexer` (850), `lower` (1735), `sourcemap` (221), `lsp/symbols` (93) | Lexer, lowering passes, source maps, document symbols |
| 3 | `parser` (2115), `codegen` (1643), `highlight` (169), `lsp/repair` (877) | Parser, Gleam generation, syntax highlighting, LSP buffer repair |
| 4 | `deriving` (1305), `formatter` (1613) | `@derive` expansion, formatter |
| 5 | `associated` (645) | Associated-function resolution |
| 6 | `compiler` (57) | Compiler orchestration |
| 7 | `project` (576) | Projects, `.beabuild` sync, compile cache |
| 8 | `entrypoint` (420), `gleam_output` (403), `shell` (745), `lsp/index` (685) | `bea run`, Gleam output rewriting, the shell (GSH), the LSP index |
| 9 | `imports` (451), `lsp/assist` (471) | Organising imports, LSP completion helpers |
| 10 | `lsp/server` (2797) | The language server |
| 11 | `cli` (963) | The `bea` command |
| 12 | `bea` (16) | `main` |

FFI: `bea_ffi.erl` (processes, files, terminal, hashing) and
`bea_signal.erl` (Ctrl+C forwarding) are Erlang, not Gleam; they stay
Erlang. 37 `@external` functions bind them (and a few `erlang`/`lists`
functions).

### Language features the modules need

Everything the compiler uses exists in Bea already: custom types with
labelled fields, generics, opaque types, type aliases, constants,
`@external` functions without a body, `use`, `case` with guards,
alternatives and several subjects, `let assert` (a refutable assignment),
string prefix patterns (`"a" <> rest`), bit array patterns with `bytes`,
`bits`, `size(n)` and `utf8` options (the lexer, JSON parser and buffer
repair work on bytes), anonymous functions, function captures, labelled
arguments, record updates and tuple indexing. Bea reads most Gleam syntax
as is (`#(a, b)`, `[x, ..rest]`, `Ctor(..base, f: v)`, `&&`, `||`), so a
module translates almost token for token. What differs:

- named functions are `def`, and there is no `let`/`let assert` (Bea emits
  `let assert` exactly when a pattern can fail);
- `#{` in a string literal interpolates, so literal ones are written `\#{`;
- a line starting with `-` starts a new expression outside brackets;
- `def`, `cond`, `return`, `and`, `or` and `not` are keywords: three private
  identifiers were called that (`parser.def`, `lower.cond` and a local
  `return` in `lsp/index`).

Found by translating every module before starting:

- Bea rejected the trailing comma Gleam's formatter puts after `..` in a
  multi-line constructor pattern (`Ctor(\n  a:,\n  ..,\n)`), a parser bug.
- Regular `//` comments and record-field doc comments aren't forwarded to
  the generated Gleam (only the generated text is affected).

### Bootstrapping difficulties

- The compiler compiles itself, so a compiler must exist before the first
  build: a trusted seed, built from the last all-Gleam revision.
- The Gleam tests and build need the generated modules in a Gleam
  package's `src/`, so generation runs before `gleam build`/`gleam test`,
  and generated files must never be mistaken for, or overwrite,
  hand-written ones.
- Bea compiles a module with knowledge of the project's other modules
  (single-constructor types, derived functions), so the compiler sources
  are compiled as one project, not file by file.

## 2. Plan

1. **Trusted bootstrap**: pin the seed by tree hash; stages A, B, C with
   B and C required to agree.
2. **Source layout**: authoritative sources in `compiler/src`, `src/`
   generated and guarded, module names and API unchanged so `test/` keeps
   testing the same modules.
3. **Migration tooling**: a mechanical translator, `bea format`, and an
   equivalence check of the original Gleam against the Gleam regenerated
   from the translation. Nothing rewritten by hand, so no algorithm or data
   structure changes.
4. **Staged migration**, one commit per stage, each passing every gate.
5. **Verification** of A, B and C on outputs and test suites.

## 3. What was done

Commits, in order, after the base revision (417b591):

1. `feat(parser): add single-constructor record shorthand` (Part 1, before
   any self-hosting work).
2. `docs: audit the compiler and plan its migration to Bea`.
3. `fix(parser): accept a trailing comma after `..` in constructor patterns`,
   with a regression test (`test/regressions_test.gleam`).
4. `refactor: rename private identifiers that are Bea keywords`
   (`def` → `def_`, `cond` → `cond_`, `return` → `return_`). This commit's
   tree is the seed.
5. `build: build the compiler from compiler/src with a trusted bootstrap`:
   the move to `compiler/src` (unchanged files), the bootstrap, the
   verification script, the bootstrap tests, the corpus of invalid
   programs, CI.
6. `tools: add the Gleam-to-Bea migration tooling`, and a fix to its check.
7. The migration, in the planned order:

   | Stage | Modules |
   | --- | --- |
   | AST and utilities | `span`, `style`, `system`, `ast`, `diagnostic`, `doc`, `sourcemap` |
   | Code generation and formatting | `codegen`, `formatter`, `highlight`, `imports` |
   | Lowering | `lower` |
   | Deriving and associated functions | `deriving`, `associated` |
   | Parser | `parser` |
   | Lexer | `lexer` |
   | Compiler orchestration | `compiler`, `project`, `gleam_output`, `entrypoint` |
   | CLI and remaining tooling | `cli`, `bea`, `shell`, `line_editor`, `lsp/assist`, `lsp/index`, `lsp/json`, `lsp/position`, `lsp/repair`, `lsp/server`, `lsp/symbols`, `lsp/text`, `lsp/transport` |

8. `build(bootstrap): read a recorded chain of trust from seed.env`, and
   this documentation.

Each stage was translated with `tools/migrate/migrate.sh`, formatted with
`bea format`, and committed only after all of these passed:

- `tools/migrate/check.sh`: the bootstrap, then the seed's Gleam compared
  with the Gleam that compiler A generated from `compiler/src`, parsed with
  glance, definition by definition: all 33 modules the same program at
  every stage (no differences, not even `let` versus `let assert`);
- `scripts/bootstrap.sh`: A and B generate identical Gleam;
- `gleam format --check` and `bea format --check compiler/src`;
- `gleam test`, `scripts/test_examples.sh`, `scripts/test_tooling.sh`,
  `test/lsp/test_lsp.py`;
- `scripts/verify_bootstrap.sh --outputs-only`, and the full verification
  (suites against B and C) for the last stage.

## 4. Verification

`scripts/verify_bootstrap.sh` compares the compilers:

- **Output, byte for byte, for A, B and C**: `bea transpile` and
  `bea format --stdin` of every `.bea` file in the repository (the
  compiler's modules, the exercism examples, the fixtures, the test
  projects and the invalid programs of `test_projects/invalid`: lexer,
  parser, recovery, record shorthand, deriving, associated-function,
  lowering and reserved-word errors), whole-project compilation
  (`beacode/`, the fixtures, `test_projects/deriving` and
  `test_projects/broken`, which has a duplicate module and an invalid
  module name), and `--help`, `--version`, `run --help`, usage errors, an
  unknown command, a missing file, `format --check` and `pack`. Standard
  output, standard error and exit status must be identical, except for
  the changes `bootstrap/changes-since-seed` declares between A and B.
- **Behaviour, for B and for C**: the Gleam unit tests (run in each
  stage's own package, against that stage's modules), the end-to-end
  tests (which compile and run the fixtures and examples and compare what
  they print, and check the formatter's idempotence), the tooling tests
  (`bea run`, Gleam tools, mixed projects, generated code, diagnostics) and
  the language server test.

Textual equality is not the only evidence: the compiled programs are run,
and the test suites exercise the compilers' behaviour, including on
invalid programs.
