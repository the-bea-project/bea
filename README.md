# Bea

Bea is an ergonomic language that transpiles to [Gleam](https://gleam.run). It compiles to plain, readable Gleam, so it gets Gleam's type checker, both compile targets (Erlang and JavaScript), the whole Hex ecosystem and Gleam's language server for free — while borrowing ergonomics from Elixir:

- multi-clause functions with pattern matching and guards
- early `return`, `?` for error propagation, and `else` guards
  (`Ok(user) = auth(req) else unauthorized()`)
- `if`/`else`, `cond` and `case` as expressions
- string interpolation: `"Hello, #{name}!"`
- `(a, b)` tuples, `%{"k": v}` maps, `[head | tail]` lists
- updates with `|`: `User(user | name: "Bea")`, `%{scores | "bea": 1}`
- automatic imports for the standard library (`list.map`, `Some`, `Dict`, ...)
- no macros, fully type safe

```bea
import gleam/io

pub type Shape {
  Circle(r: Float)
  Rect(w: Float, h: Float)
}

pub def area(Circle(r)) {
  3.14 *. r *. r
}

pub def area(Rect(w, h)) {
  w *. h
}

pub def describe(shapes: List(Shape)) -> Result(String, String) {
  if shapes == [] {
    return Error("no shapes")
  }
  total = shapes |> list.map(area) |> float.sum
  Ok("total area: #{float.to_string(total)}")
}

pub def main() {
  case describe([Circle(1.0), Rect(2.0, 3.0)]) {
    Ok(text) -> io.println(text)
    Error(e) -> io.println_error(e)
  }
}
```

## Getting started

Bea needs Gleam (1.18+) and Erlang/OTP 27+ installed.

```sh
bea new my_app
cd my_app
bea run
```

A Bea project looks like a Gleam project, with `bea.toml` instead of
`gleam.toml` (same format) and `.bea` files in `src/`:

```text
my_app/
  bea.toml        # name, version, dependencies, target... (gleam.toml format)
  manifest.toml   # lock file, managed by bea — commit it
  src/
    my_app.bea    # `bea run` runs this module's `main`
    my_app/util.bea
    my_app/fast.gleam   # Gleam modules can live alongside Bea modules
    my_app_ffi.erl      # so can Erlang / JavaScript FFI files
  .beabuild/      # the generated Gleam project (ignored by git)
```

## The `bea` command

| Command | What it does |
| --- | --- |
| `bea new NAME` | Create a project |
| `bea add PKG...` (`--dev`) | Add Hex dependencies, e.g. `bea add lustre gleam_json` |
| `bea remove PKG...` | Remove dependencies |
| `bea update [PKG...]` | Update dependencies |
| `bea deps list\|download\|tree` | Inspect dependencies |
| `bea check` | Type check |
| `bea build` | Build (`--target javascript`, `--warnings-as-errors`, ...) |
| `bea run [FILE.bea \| -m MODULE] [-- ARGS]` | Run a module's `main` |
| `bea format [--check] [--stdin] [--imports] [PATHS]` | Format `.bea` files (`--imports` also organises imports) |
| `bea shell` | Interactive Bea shell (REPL) in the project, built on GSH |
| `bea transpile FILE.bea` | Print the Gleam generated for a file (`--stdin` reads the source from stdin) |
| `bea transpile --out DIR` | Write the project out as a plain Gleam project ("eject") |
| `bea export erlang-shipment\|escript\|...` | Gleam's export commands |
| `bea publish` | Publish to Hex (as the generated Gleam package) |
| `bea hex ...` | Hex account commands |
| `bea clean` | Delete `.beabuild/` |
| `bea lsp` | Language server for editors |

Flags Bea doesn't know are passed to Gleam. Errors from Gleam are rewritten to
point at your `.bea` files, with the Bea source shown in the snippet:

```text
error: Type mismatch
   ┌─ src/demo.bea:16:22
   │
16 │   label = "n is " <> n
   │                      ^

The <> operator expects arguments of this type:
    String
```

`echo` output and runtime stack traces are rewritten the same way.

Output is coloured in one purple accent on dark greys (red and yellow only
for errors and warnings), and code is syntax highlighted: the Bea lines in
error snippets, and the Gleam printed by `bea transpile` on a terminal.
`NO_COLOR` turns colours off, `FORCE_COLOR` forces them.

Outside a project, `bea run some/dir/file.bea` treats `some/dir` as the
source directory, which is handy for scripts and exercises.

`bea run` builds the project and runs `main` the way `gleam run` does (the
OTP application is started, panics are printed with Bea locations), but from
the project root rather than from `.beabuild/`, so relative paths and `.env`
files resolve against your project. `--target javascript` runs it on Node
(`--runtime bun` / `deno` for those).

Ctrl+C stops the program and gives the terminal back exactly as it was.
Programs started by an Erlang VM live in a session of their own, so they
never see the Ctrl+C themselves: the launcher starts Bea's VM with `+Bi` and
turns the interrupt into a SIGTERM that Bea forwards to the program, waiting
for it to be gone before exiting (a gleepack build does the same; its runtime
starts programs in Bea's session, so Bea moves them to their own with
`setsid`). Should Bea itself be killed, a watchdog removes the program and
everything it started. (Before, the program kept
running, holding its port, and reset the terminal mode when it finally exited
— the shell then echoed its own terminal queries as `^[]11;rgb:...^[[?62;52;c`
garbage.) You no longer need `ERL_FLAGS=+B` for this.

### Using Gleam packages

Any Gleam package works directly — there is nothing to wrap:

```bea
import lustre/attribute.{class}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event

pub type Msg {
  Increment
  Decrement
}

pub def update(count, Increment) { count + 1 }
pub def update(count, Decrement) { count - 1 }

pub def view(count: Int) -> Element(Msg) {
  html.div([class("counter")], [
    html.button([event.on_click(Decrement)], [html.text("-")]),
    html.p([], [html.text("Count: #{int.to_string(count)}")]),
    html.button([event.on_click(Increment)], [html.text("+")]),
  ])
}
```

`use` works exactly as in Gleam, so APIs built around it (decoders, wisp
handlers, ...) read naturally:

```bea
pub def user_decoder() -> decode.Decoder(User) {
  use name <- decode.field("name", decode.string)
  use age <- decode.field("age", decode.int)
  decode.success(User(name:, age:))
}
```

### The shell

`bea shell` starts an interactive shell in the project (or, outside a
project, in a scratch project in `~/.cache/bea/shell`):

```text
bea> import beahive/services/cache
bea> c = cache.setup_rate_cache()
bea> def double(n) { n * 2 }
bea> [1, 2, 3] |> list.map(double)
[2, 4, 6] : List(Int)
```

You type Bea; each input is compiled by Bea and evaluated by
[GSH](https://gsh.hexdocs.pm), the Gleam shell, which Bea depends on.
Bindings, imports, `def`s and `type`s carry over to later inputs, and the
side effects of earlier inputs don't run again. The line is highlighted as
you type (on OTP 28+; OTP 27 reads plain lines), input continues on the
next line while brackets are open, and history is kept across sessions. `:help` lists the commands: `:gleam` shows
the Gleam each input compiles to, `:cc` rebuilds the project and reloads
what changed, `:b` lists the bindings.

`?`, `return` and `else` guards leave a function, so in the shell they go
inside a `def`. The shell runs on the Erlang target, and project modules
can't have the same name as a module the shell uses itself (it warns, e.g.
for an `ffi.erl`: name it `<package>_ffi.erl`).

### Publishing

`bea publish` publishes the **generated Gleam code** to Hex. That means Bea
packages are ordinary Gleam packages: Gleam projects can depend on them, and
Bea projects depend on Gleam packages the same way. Fill in `description`,
`licences` and `repository` in `bea.toml` first; `README.md`, `LICENCE` and
`CHANGELOG.md` are included automatically.

### Building a standalone `bea` binary

The CLI is a normal Gleam program (`bea.main`). Package it with gleepack, or
with `gleam export erlang-shipment`. For development, `scripts/bea` runs the
CLI straight from this checkout after `gleam build`.

Ctrl+C works with both: `scripts/bea` starts the VM with `+Bi` and turns
SIGINT into a SIGTERM, and gleepack's runtime does that conversion itself.
Any other launcher should do the same; without it, Ctrl+C still stops the
program (through the watchdog), but Bea itself dies before it.

## Language guide

### Functions

```bea
pub def add(a: Int, b: Int) -> Int {
  a + b
}

// Labelled parameters: callers write `scale(by: 2, point: p)`
pub def scale(by factor: Int, point p: Point) -> Point {
  Point(p | x: p.x * factor, y: p.y * factor)
}
```

Consecutive `def`s with the same name are clauses of one function. They can
match on patterns and have guards. An optional body-less head declares the
types:

```bea
def count(items: List(a), acc: Int) -> Int

def count([], acc) {
  acc
}

def count([_ | rest], acc) if acc < 1000 {
  count(rest, acc + 1)
}

def count(_, acc) {
  acc
}
```

Clauses become a single Gleam function with a `case`, so recursion in tail
position stays tail-call optimised.

### Variables and patterns

There is no `let`. Assignments destructure, and Bea emits `let assert` only when
the pattern can actually fail:

```bea
(name, age) = person          // let #(name, age) = person
[first | _] = names           // let assert [first, ..] = names
Point(x:, y:) = point         // label shorthand
"Team " <> team = label       // string prefix
total: Int = 0                // with an annotation
```

Because there are no statement terminators, a `(` or `[` only continues an
expression on the *same line*, and a line starting with `-` starts a new
expression. Binary operators like `|>`, `<>` and `==` at the start of a line
continue the previous one, so pipelines can be split over lines.

### Control flow

```bea
// if is an expression
label = if score > 90 { "great" } else if score > 50 { "ok" } else { "hmm" }

// cond: the first true condition wins (`_` or `True` is the fallback)
cond {
  temp < 0 -> "freezing"
  temp < 20 -> "mild"
  _ -> "hot"
}

// case, with alternatives, guards and several subjects
case x, y {
  0, 0 -> "origin"
  0, _ | _, 0 -> "on an axis"
  a, b if a == b -> "diagonal"
  _, _ -> "somewhere"
}
```

`return` can be used anywhere a statement goes — in the middle of a function,
inside `if`/`case` branches, inside anonymous functions:

```bea
def find_user(id: Int) -> Result(User, String) {
  if id < 0 {
    return Error("invalid id")
  }
  user = case lookup(id) {
    Some(u) -> u
    None -> {
      log("missing #{int.to_string(id)}")
      return Error("not found")
    }
  }
  Ok(user)
}
```

Early returns compile to `bool.guard`/`bool.lazy_guard` or nested `case`s;
the returned expression is only evaluated when the branch is taken.

### Error propagation with `?`

`expr?` unwraps an `Ok` or returns the `Error` from the enclosing function. It
works inside any expression; after a pipeline it applies to the whole pipeline:

```bea
def total(a: String, b: String) -> Result(Int, Nil) {
  x = int.parse(a)?
  Ok(x + int.parse(b)?)
}

def parse_port(text: String) -> Result(Int, Nil) {
  port = text |> string.trim |> int.parse?
  Ok(port)
}

// Short-circuiting is respected: `parse` only runs when `strict` is True.
ok = strict and parse(s)? > 0
```

### Guards: `else`

A guard is an assignment that must match, with what to return when it
doesn't. It's `?` for any pattern, with any exit value, and it keeps the
code flat:

```bea
def first_even(xs: List(Int)) -> Result(Int, String) {
  [first, ..] = list.filter(xs, int.is_even) else Error("no even number")
  Ok(first)
}
```

When the value doesn't match the pattern, the function returns what
follows `else`, and the rest of the block never runs. Like `?` and
`return`, a guard leaves the function from anywhere (only an anonymous
function's own guards stop at that function).

- **Boolean guards** drop the pattern: `allowed(ip) else too_many()`.
- **With `?`**, the pattern matches the `Ok` value and the `else` can bind
  the error: `user = auth(req)? else reason -> unauthorized(reason)`.
- **Any pattern** can bind what didn't match: `Some(v) = lookup(k) else
  None -> default`.
- The fallback can be a block (`else { log("..."); fallback }`), an
  explicit `else return x`, and can go on the next line when it is long.

Guards compile to plain `case` expressions: the rest of the block becomes
the matching branch.

#### Middleware

Middleware that only decides whether the request goes on is a guard; the
check reads top to bottom, without callbacks:

```bea
pub def handle_request(req: Request(Connection), ctx: Context) -> Response(Body) {
  use <- log_request(req)
  !rate_limiters.blocked(client_ip(req), ctx) else too_many_requests()
  user = auth.current_user(req, ctx)? else reason -> unauthorized(reason)

  case req.method, request.path_segments(req) {
    http.Get, [] -> handle_root(ctx, user)
    _, _ -> not_found()
  }
}
```

Middleware that does something *after* the handler (logging the
response, timing, adding headers, rescuing errors) wraps the rest of the
function, which is what `use` is for: `log_request` above is an ordinary
function taking `next`:

```bea
pub def log_request(req: Request(a), next: fn() -> Response(b)) -> Response(b) {
  response = next()
  io.println(req.path <> " -> " <> int.to_string(response.status))
  response
}
```

So: `use` for middleware *around* the handler, guards for middleware
*before* it, and `?` when the check already returns a `Result`.

### Data

```bea
point = (1, 2)              // tuples (`(x,)` is a 1-tuple, `()` is Nil)
x = point.0

numbers = [1, 2, 3]
more = [0 | numbers]        // also: [a, b | rest]

scores = %{"bea": 10, "gleam": 20}
scores = %{scores | "bea": 11}     // insert / update keys

user = User(name: "Ada", admin: False)
admin = User(user | admin: True)   // record update

bits = <<header:bits, length:16-big, "ok":utf8>>
```

### Strings

```bea
"Hello, #{name}!"          // interpolation of String expressions
"Tab\tquote\"newline\n"    // escapes, \u{1F600}
"not \#{interpolated}"     // escape the #
`raw \n "string"`          // backticks: no escapes at all
```

### Types

```bea
pub type Shape {
  Circle(radius: Float)
  Square(side: Float)
}

pub opaque type Email {         // constructors private to the module
  Email(String)
}

pub type Usd                    // no constructors: phantom/external types

pub type Money(currency) {
  Money(amount: Int)
}

pub type Scores = Dict(String, Int)

pub const max_players: Int = 4
```

### Talking to Erlang and JavaScript

```bea
pub type Tree(k, v)

@external(erlang, "gb_trees", "empty")
pub def new_tree() -> Tree(k, v)

@external(erlang, "my_app_ffi", "now")
@external(javascript, "./my_app_ffi.mjs", "now")
pub def now() -> Int
```

Put `my_app_ffi.erl`/`.mjs` in `src/` and Bea copies them across.

### Imports

```bea
import gleam/dict.{type Dict}
import lustre/element/html
import my_app/util as u
```

Standard library modules (`list`, `dict`, `set`, `string`, `int`, `float`,
`result`, `option`, `io`, `bool`, `order`, `pair`, `function`, `bit_array`,
`string_tree`, `bytes_tree`, `dynamic`, `decode`, `uri`) and the names
`Option`, `Some`, `None`, `Dict`, `Set`, `Order`, `Lt`, `Eq`, `Gt` are imported
automatically when used. This is scope aware: a variable called `list` or
`result` is never mistaken for a module.

### Numbers

Gleam operators work as usual (`+`, `*.`, `<.`, `%`, ...). Gleam can't negate
a float variable with `-`, so Bea adds `-.x`, which compiles to
`float.negate(x)`. `0xFF`, `0b1010`, `0o17`, `1_000` and `2.5e3` are all
valid literals.

### Gleam names that are Bea keywords

`and`, `or`, `not`, `return`, `def` and `cond` are keywords in Bea but ordinary
names in Gleam. They still work where Gleam code needs them: as module
members and as labels, e.g. `bool.and(a, b)` or
`use <- bool.guard(when: x > 3, return: 0)`.

### Everything else from Gleam

`use`, `assert`, `todo`, `panic as "..."`, `echo` (and `x |> echo`),
function captures (`list.map(xs, add(_, 1))`), labelled arguments, doc comments
(`///`, `////` — they show up in hovers and generated docs).

### Evaluation order

`?` keeps left-to-right evaluation: in `f(log("a"), g()?)`, `log("a")` still
runs first, and the assertion message in `assert ok as msg()?` is only
evaluated when the assertion fails.

## Known limitations

- Type errors in code with early returns are sometimes reported on the `if`
  holding the `return` rather than on the line Gleam finds inconsistent,
  because Gleam sees the rest of the function as the guard's continuation.
- Doc comments on individual record fields aren't passed on to Gleam.
- `bea test` and `bea docs` aren't implemented; run the Gleam equivalents
  inside `.beabuild/` if you need them.

## Editor support

`bea lsp` is a language server. It runs `gleam lsp` on the generated project and
translates between Bea and Gleam positions, so you get Gleam's type checking and
IDE features on `.bea` files:

- diagnostics (Bea syntax errors, and Gleam type errors on the right Bea span)
- hover with the declaration (parameter names, where it comes from) and doc
  comments, go to definition (into Bea files, your Gleam modules, or
  dependency sources), find references, highlights, rename
- completion that works while you type: right after `timestamp.`, inside an
  unfinished call or constructor (`Context(timestamp.|`), with the brackets
  not closed yet. The buffer is compiled with a placeholder at the cursor and
  whatever is open closed (`bea/lsp/repair`)
- completion of functions, constants and constructors from modules you
  haven't imported — your own modules and your dependencies' — adding the
  `import` when you pick one; functions complete as calls, `name(|)`, with
  their signature shown (`bea.completion.callParentheses` in VS Code)
- signature help that follows the argument you are on, labels included,
  shows parameter names (`timestamp.add(timestamp: Timestamp, duration:
  Duration)`) and works in unfinished code
- `@external` interop: go to definition and hover on an `@external(...)`
  open the Erlang / JavaScript function it binds (`.erl` / `.mjs` in `src/` or
  in a dependency)
- completion of locals and functions everywhere in a function: `case`,
  `cond` and `if` branches, after `?` and early returns, in `use` callbacks
  (Bea turns these into Gleam code of another shape; positions are mapped
  onto the right Gleam token)
- document symbols, and formatting (Bea's own formatter), which also
  **organises imports**, like `goimports`: the standard library
  (`gleam/...`), other dependencies and the project's own modules in sorted
  groups separated by a blank line; unused imports and unqualified names
  removed; and missing imports added when there is no doubt (`process.sleep`
  is used, only `gleam/erlang/process` has a `sleep`). When two modules could
  be meant, nothing is added. Turn it off with `bea.format.organizeImports`
  in VS Code (initialization option `format.organizeImports`).

**VS Code**: see `editors/vscode` (`npm install && npx vsce package`). It
also has **Bea: Show Generated Gleam** to see what the current buffer compiles
to.

**Neovim** (nvim-lspconfig style):

```lua
vim.filetype.add({ extension = { bea = "bea" } })
vim.api.nvim_create_autocmd("FileType", {
  pattern = "bea",
  callback = function(args)
    vim.lsp.start({
      name = "bea",
      cmd = { "bea", "lsp" },
      root_dir = vim.fs.root(args.buf, { "bea.toml" }),
    })
  end,
})
```

**Helix** (`languages.toml`):

```toml
[[language]]
name = "bea"
scope = "source.bea"
file-types = ["bea"]
roots = ["bea.toml"]
language-servers = ["bea-lsp"]
comment-token = "//"

[language-server.bea-lsp]
command = "bea"
args = ["lsp"]
```

Set `BEA_LSP_LOG=1` to get a debug log on stderr.

## How it works

```text
.bea ──lexer──▶ tokens ──parser──▶ AST ──lower──▶ AST ──codegen──▶ .gleam + source map
                (spans,            (Pratt,         (cond, ?,         (pretty printer
                 comments)          recovery)       returns,          with marks)
                                                    clauses)
```

| Module | Role |
| --- | --- |
| `bea/lexer` | Byte-based lexer with exact spans; keeps comments; string interpolation |
| `bea/parser` | Recursive descent + precedence climbing (Gleam's table); error recovery per definition |
| `bea/ast` | Syntax tree, every node has a span |
| `bea/lower` | `cond` → `if`, `else` guards → `case`, `?` hoisting (tail-aware), early returns → guards/continuations, multi-clause → `case` |
| `bea/codegen` | Gleam printer, scope-aware import planning, `let` vs `let assert` |
| `bea/doc` | Wadler-style pretty printer that records source mappings |
| `bea/sourcemap` | Bea ↔ Gleam position translation |
| `bea/formatter` | Bea formatter with comment anchoring and a parse-back safety check |
| `bea/imports` | Organising imports: grouping, sorting, removing unused ones, adding obvious ones |
| `bea/project` | Project discovery, `.beabuild` sync, manifest handling, compile cache |
| `bea/gleam_output` | Rewrites Gleam CLI output to Bea locations |
| `bea/cli` | The `bea` command |
| `bea/style`, `bea/highlight` | The CLI's colours, and syntax highlighting of Bea and Gleam |
| `bea/shell`, `bea/line_editor` | `bea shell`: Bea front end for GSH's evaluator, and its line editor |
| `bea/lsp/*` | JSON, JSON-RPC transport, the proxying language server |
| `bea/lsp/repair` | Makes the buffer being typed compile (placeholder, closing brackets), finds the call around the cursor |
| `bea/lsp/index` | Public API of the project and its dependencies (parameter names, docs, unimported values), FFI lookup |
| `bea_signal`, `bea_ffi` | Ctrl+C forwarding, child processes with a watchdog |

## Development

```sh
gleam test                      # unit tests
gleam build && export PATH=$PWD/scripts:$PATH
scripts/test_examples.sh        # fixtures, exercism examples, formatter, via the CLI
python3 test/lsp/test_lsp.py    # language server integration test
python3 test/cli/test_interrupt.py  # Ctrl+C in `bea run` leaves the terminal alone
```

`beacode/` holds Bea solutions to the Gleam exercism track; `test/fixtures/`
holds programs with expected output that cover the remaining exercism concepts
(let assertions, bit arrays, IO/Nil, opaque and phantom types, external
functions, `use`) and Bea's own features.
