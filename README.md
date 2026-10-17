# Bea

Bea is a friendlier syntax for [Gleam](https://gleam.run). It compiles to plain,
readable Gleam, so it gets Gleam's type checker, both compile targets (Erlang and
JavaScript), the whole Hex ecosystem and Gleam's language server for free —
while borrowing ergonomics from Elixir:

- multi-clause functions with pattern matching and guards
- early `return`, and `?` for error propagation
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
| `bea format [--check] [--stdin] [PATHS]` | Format `.bea` files |
| `bea transpile FILE.bea` | Print the Gleam generated for a file |
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

Outside a project, `bea run some/dir/file.bea` treats `some/dir` as the
source directory, which is handy for scripts and exercises.

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
- `bea test`, `bea docs` and `bea shell` aren't implemented; run the Gleam
  equivalents inside `.beabuild/` if you need them.

## Editor support

`bea lsp` is a language server. It runs `gleam lsp` on the generated project and
translates between Bea and Gleam positions, so you get Gleam's type checking and
IDE features on `.bea` files:

- diagnostics (Bea syntax errors, and Gleam type errors on the right Bea span)
- hover with types and doc comments, go to definition (into Bea files, your
  Gleam modules, or dependency sources), find references, highlights, rename
- completion — including right after `module.` while the line doesn't parse yet
- signature help, document symbols, and formatting (Bea's own formatter)

**VS Code**: see `editors/vscode` (`npm install && npx vsce package`).

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
| `bea/lower` | `cond` → `if`, `?` hoisting (tail-aware), early returns → guards/continuations, multi-clause → `case` |
| `bea/codegen` | Gleam printer, scope-aware import planning, `let` vs `let assert` |
| `bea/doc` | Wadler-style pretty printer that records source mappings |
| `bea/sourcemap` | Bea ↔ Gleam position translation |
| `bea/formatter` | Bea formatter with comment anchoring and a parse-back safety check |
| `bea/project` | Project discovery, `.beabuild` sync, manifest handling, compile cache |
| `bea/gleam_output` | Rewrites Gleam CLI output to Bea locations |
| `bea/cli` | The `bea` command |
| `bea/lsp/*` | JSON, JSON-RPC transport, the proxying language server |

## Development

```sh
gleam test                      # unit tests
gleam build && export PATH=$PWD/scripts:$PATH
scripts/test_examples.sh        # fixtures, exercism examples, formatter, via the CLI
python3 test/lsp/test_lsp.py    # language server integration test
```

`beacode/` holds Bea solutions to the Gleam exercism track; `test/fixtures/`
holds programs with expected output that cover the remaining exercism concepts
(let assertions, bit arrays, IO/Nil, opaque and phantom types, external
functions, `use`) and Bea's own features.
