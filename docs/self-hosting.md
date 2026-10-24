# Self-hosting the Bea compiler

Bea transpiles to Gleam. This document is the plan for writing Bea's own
compiler in Bea while it keeps generating Gleam, so that the compiler is
built by the toolchain it implements:

```text
Bea compiler source (.bea)
          |
          v
Trusted bootstrap compiler
          |
          v
Generated Gleam
          |
          v
Gleam compiler
          |
          v
Executable Bea compiler
```

Gleam stays the backend: its type checker, standard library, runtime and
build tool are used exactly as before. Nothing here adds a backend, a type
checker or a runtime.

## 1. Audit (before the migration)

### Build and transpilation pipeline

- The repository root is a Gleam package (`gleam.toml`, `manifest.toml`)
  named `bea`. `src/` holds the compiler as 33 Gleam modules (about 21 000
  lines) and two Erlang FFI files; `test/` holds the gleeunit suite.
- `gleam build` produces the compiler; `scripts/bea` runs it from
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
- CI (`.github/workflows/test.yml`): `gleam format --check`, `gleam test`,
  then `scripts/test_examples.sh`, `scripts/test_tooling.sh` and
  `test/lsp/test_lsp.py` through the `bea` launcher.

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

FFI: `bea_ffi.erl` (processes, files, terminal, hashing) and `bea_signal.erl`
(Ctrl+C forwarding) are Erlang, not Gleam; they stay Erlang. 37
`@external` functions bind them (and a few `erlang`/`lists` functions),
mostly from `system`, `lsp/transport`, `line_editor` and `shell`.

### Language features the modules need

Everything the compiler uses exists in Bea already: custom types with
labelled fields, generics, opaque types, type aliases, constants,
`@external` functions without a body, `use`, `case` with guards,
alternatives and several subjects, `let assert` (a refutable assignment),
string prefix patterns (`"a" <> rest`), bit array patterns with `bytes`,
`bits`, `size(n)` and `utf8` options (the lexer, JSON parser and buffer
repair work on bytes), anonymous functions, function captures, labelled
arguments, record updates and tuple indexing. Bea reads most Gleam syntax as
is (`#(a, b)`, `[x, ..rest]`, `Ctor(..base, f: v)`, `&&`, `||`), so a
module translates almost token for token. What differs:

- named functions are `def`, and there is no `let`/`let assert` (Bea emits
  `let assert` exactly when a pattern can fail);
- `#{` in a string literal interpolates, so literal ones are written `\#{`;
- a line starting with `-` starts a new expression outside brackets;
- `def`, `cond`, `return`, `and`, `or` and `not` are keywords: three private
  identifiers are called that (`parser.def`, `lower.cond` and a local
  `return` in `lsp/index`) and are renamed, in Gleam, before the migration.

Found while trying the translation on every module:

- Bea rejects the trailing comma Gleam's formatter puts after `..` in a
  multi-line constructor pattern (`Ctor(\n  a:,\n  ..,\n)`): a parser bug,
  fixed in Gleam (with a regression test) before the migration.
- Regular `//` comments are not forwarded to the generated Gleam (only `///`
  and `////` are), and neither are doc comments on record fields (a known
  limitation in the README). Both only change the generated text; the Bea
  source keeps every comment.

### Bootstrapping difficulties

- The compiler compiles itself, so a compiler must exist before the first
  build: a trusted seed, built from the last all-Gleam revision, compiles
  the Bea sources the first time.
- The Gleam tests and the Gleam build need the generated modules in a Gleam
  package's `src/`, so generation has to run before `gleam build`/`gleam
  test`, and generated files must never be mistaken for, or overwrite,
  hand-written ones.
- Bea compiles a module with knowledge of the project's other modules
  (single-constructor types, derived functions), so the compiler sources
  are compiled as one project, not file by file.

## 2. Plan

1. **Trusted bootstrap.** Pin the last all-Gleam revision as the seed by
   its git *tree* hash (content addressed, so it survives rebases and
   `git am`, unlike a commit hash), and add `scripts/bootstrap.sh`: build the
   seed (compiler A), compile the Bea sources with it and build the result
   (compiler B), compile them again with B (compiler C), require the Gleam
   generated by A and by B to be identical, and install it.
2. **Source layout.** Move the authoritative compiler sources to
   `compiler/src/` (Bea modules, Gleam modules not migrated yet, Erlang
   FFI). The root `src/` becomes generated output, ignored by git and
   written only by the bootstrap, which refuses to overwrite files it didn't
   write or that were edited after it wrote them. Module names, the package
   name and the public API stay the same, so `test/` keeps testing the
   compiler through the same modules.
3. **Migration tooling.** A mechanical translator (`tools/migrate`) does the
   few rewrites listed above, `bea format` gives the result the canonical
   Bea layout, and an equivalence checker parses the original Gleam and the
   Gleam regenerated from the Bea translation with `glance` and compares
   them definition by definition. Nothing is rewritten by hand during the
   migration, so no algorithm or data structure changes with it.
4. **Staged migration**, one commit per stage, each one passing the full
   suite (Gleam tests, end-to-end, tooling and LSP tests), the bootstrap
   (A, B, C) and the equivalence check before it is committed:
   1. AST definitions and utilities: `span`, `style`, `system`, `ast`,
      `diagnostic`, `doc`, `sourcemap`
   2. Code generation and formatting: `codegen`, `formatter`, `highlight`,
      `imports`
   3. Lowering: `lower`
   4. Deriving and associated functions: `deriving`, `associated`
   5. Parser: `parser`
   6. Lexer: `lexer`
   7. Compiler orchestration: `compiler`, `project`, `gleam_output`,
      `entrypoint`
   8. CLI and remaining tooling: `cli`, `bea`, `shell`, `line_editor`,
      `lsp/*`

   Mixed sources work at every stage: Bea and Gleam modules of
   `compiler/src` are compiled together as one Bea project.
5. **Verification.** Compare compilers A, B and C on the test suites and on
   the output (generated Gleam, formatter output, diagnostics, CLI output)
   for every Bea program in the repository and a corpus of invalid ones.
