# Bea

<p align="center">
  <img src="beatrix.svg" alt="Beatrix — Bea mascot" width="180">
</p>

<h1 align="center">Bea</h1>

<p align="center">
  An ergonomic language that transpiles to Gleam.
</p>

>Bea is an ergonomic language that transpiles to [Gleam](https://gleam.run). It compiles to plain, readable Gleam, so it gets Gleam's type checker, both compile targets (Erlang and JavaScript), the whole Hex ecosystem and Gleam's language server for free — while borrowing ergonomics from Elixir:

- multi-clause functions with pattern matching and guards
- early `return`, `?` for error propagation, and `else` guards
  (`Ok(user) = auth(req) else unauthorized()`)
- `if`/`else`, `cond` and `case` as expressions
- string interpolation: `"Hello, #{name}!"`
- `(a, b)` tuples, `%{"k": v}` maps, `[head | tail]` lists
- updates with `|`: `User(user | name: "Bea")`, `%{scores | "bea": 1}`
- automatic imports for the standard library (`list.map`, `Some`, `Dict`, ...)
- `@derive(decoder)`: functions such as decoders written from a record's
  fields by an ordinary library, not by the compiler, and called through
  their type: `Credentials.decoder()`
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
| `bea test [ARGS]` | Run the project's tests: the `main` of `test/<package>_test.gleam` (gleeunit, ...), from the project root |
| `bea build` | Build (`--target javascript`, `--warnings-as-errors`, ...) |
| `bea run [-m MODULE \| FILE.bea] [ARGS]` | Run a module's `main`: the project's, or a dependency's such as a Gleam tool (`bea run -m marmot migrate`) |
| `bea format [--check] [--stdin] [--imports] [PATHS]` | Format `.bea` files (`--imports` also organises imports) |
| `bea shell` | Interactive Bea shell (REPL) in the project, built on GSH |
| `bea transpile FILE.bea` | Print the Gleam generated for a file (`--stdin` reads the source from stdin) |
| `bea transpile --out DIR` | Write the project out as a plain Gleam project ("eject") |
| `bea export erlang-shipment\|escript\|...` | Gleam's export commands |
| `bea pack [-o PATH] [-m MODULE] [-t TARGET]` | Package the project into one standalone executable, with [gleepack](https://github.com/yoshi-monster/gleepack) |
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
(`--runtime bun` / `deno` for those). Nothing runs unless the build
succeeded.

Its arguments follow `gleam run`: options first, then the program's
arguments, which start at the first argument that isn't an option and are
passed on unchanged. Put them after `--` when they start with `-`:

```sh
bea run                           # main of src/<package>.bea
bea run -m app/tasks/seed         # another module of the project
bea run serve --port 4000         # the program gets ["serve", "--port", "4000"]
bea run -- --port 4000            # ... ["--port", "4000"]
bea run --help                    # help for `bea run` itself
```

Options `bea run` doesn't know are an error rather than being passed to the
build, and an unknown module or one without a public `main` gets a diagnostic
(with a hint when, say, the package was never downloaded).

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

### Gleam tools and generated code

`-m` also runs modules of dependencies, so Gleam tools work as they do with
`gleam run -m`, e.g. [Marmot](https://hex.pm/packages/marmot), which
generates typed functions for SQLite queries:

```sh
bea add sqlight
bea add --dev marmot
bea run -m marmot help
bea run -m marmot migrate --database dev.sqlite   # db/migrations/*.sql
bea run -m marmot -- --database dev.sqlite        # src/**/sql/*.sql -> src/generated/sql/
```

Tools run from the project root, so they find `src/`, `db/` & co where they
expect them, and write generated code into your `src/`. Tools read their
settings (`[tools.marmot]`) from `gleam.toml`; Bea points them at
`bea.toml` (a `gleam.toml` symlink exists while the tool runs, unless the
project has a `gleam.toml` of its own), so the settings go in `bea.toml`:

```toml
[tools.marmot]
database = "dev.sqlite"
```

Gleam modules in `src/` are compiled together with the Bea modules, wherever
they come from, so Bea code imports generated modules like any other:

```bea
import generated/sql/users_sql.{FindUserRow}
import sqlight

pub def main() {
  use db <- sqlight.with_connection("dev.sqlite")
  Ok([FindUserRow(name:, ..)]) = users_sql.find_user(db:, username: "bea")
    else panic
  io.println(name)
}
```

Bea never writes to `src/`: generated files stay where the tool put them, and
the build follows them when they are regenerated or deleted. Gleam checks the
types across Bea and Gleam modules; Bea itself also reads the record types of
the project's Gleam modules, so a pattern that can't fail (`FindUserRow(..) =
row`) compiles to `let` rather than a `let assert` Gleam would warn about.

As with `gleam run -m`, the whole project is built before a tool runs: Bea
code that imports a module the tool hasn't generated yet has to wait until it
has.

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

### Standalone executables: `bea pack`

`bea pack` packages the project into a single executable with
[gleepack](https://github.com/yoshi-monster/gleepack): the compiled project,
its dependencies and a small Erlang runtime in one file, which runs on
machines without Erlang. It suits CLIs, TUIs and dev tools on the Erlang
target (gleepack's own limits apply: no NIFs, a read-only `priv`).

```sh
bea pack                          # build/<package>, runs the package's main
bea pack -o dist/app              # somewhere else (relative to where you are)
bea pack -m app/cli               # another module's main
bea pack -t amd64-linux-otp-29.1.1 -t aarch64-macos-otp-29.1.1   # cross-build
```

gleepack is the `gleepack` executable on the PATH (from its
[releases](https://github.com/yoshi-monster/gleepack/releases)), or the one
`BEA_GLEEPACK` names, or a dev dependency of the project:

```toml
[dev_dependencies]
gleepack = { git = "https://github.com/yoshi-monster/gleepack.git", ref = "main" }
```

Bea builds the project first, so errors point at your `.bea` files, then runs
gleepack on the generated Gleam project. gleepack's settings go in
`bea.toml` under `[tools.gleepack]` (`output`, relative to the project root,
`module` and `targets`); the command line wins over them.

### Building a standalone `bea` binary

Bea itself is a Bea project, so `bea pack` in this repository builds the
`bea` binary, `build/bea` (see [Development](#development)). The binary
needs no Erlang to run; Gleam (and the Erlang it needs to build Erlang
projects) is still required for `bea build`, `run`, `check` and the like.
`bea export erlang-shipment` works too. For development, `scripts/bea` runs
the CLI this checkout has built.

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

#### Records

A type with a single constructor named like the type can list its fields
in braces:

```bea
pub type AuthToken { sub: String, role: String }

type Point { x: Float, y: Float }     // private

pub opaque type Email { address: String }

pub type Page(item) {                 // generic, as usual
  items: List(item),
  total: Int,
}
```

Each is exactly the long form, e.g. `pub type AuthToken { AuthToken(sub:
String, role: String) }`: the parser turns one into the other, so the
Gleam, `@derive`, functions through the type (`AuthToken.decoder()`),
construction (`AuthToken(sub: "u1", role: "admin")`), patterns and record
updates are the same for both. A body starting with `name:` is a record's
fields; one starting with an uppercase name lists constructors. Fields have
labels, separated by commas; a type wrapping a value without a label is
written in full, `pub type UserId { UserId(Int) }`. The formatter keeps
whichever form you wrote, and a record on one line or one field per line.

### Deriving functions: `@derive`

Decoders, encoders, form readers and the like follow the fields of a record
one by one. `@derive` writes those functions for you, from the type, with a
*deriver*: an ordinary module (Bea or Gleam) that decides what the function
does. The compiler knows no deriver and no format.

```bea
import gleam/json
import my_json/decoder          // a deriver: JSON decoding

@derive(decoder)
pub type Credentials {
  Credentials(username: String, password: String)
}

pub def login(body: String) -> Result(String, json.DecodeError) {
  Credentials(username:, ..) = decoder.from_json(body, Credentials.decoder())?
  Ok("welcome, #{username}")
}
```

`@derive(decoder)` on `Credentials` defines the function
`credentials_decoder()`: the type's name and the deriver's (as imported, so
`import x/decoder as json` gives `credentials_json()`), which Bea code
reaches through the type as `Credentials.decoder()` (see [Functions through
their type](#functions-through-their-type)). It is exactly the code you
would write by hand, which `bea transpile` shows:

```gleam
/// Derived by `@derive(decoder)` on `Credentials`.
pub fn credentials_decoder() {
  use <- decoder.record("Credentials")
  use username <- decoder.field(
    "username",
    decoder.string(),
    fn(value: Credentials) { value.username },
  )
  use password <- decoder.field(
    "password",
    decoder.string(),
    fn(value: Credentials) { value.password },
  )
  decoder.done(Credentials(username: username, password: password))
}
```

You get only what you ask for: `@derive(decoder, encoder)` for both, and
credentials that should never be serialised simply don't derive an
encoder. The functions are as public as the type's constructor (private for
an opaque type), and appear right after the type.

**Field types.** A field's part (`decoder.string()` above) comes from its
type:

- a type parameter: an argument of the function, so `Page(item)` gives
  `page_decoder(item_decoder)` (parameters only phantom types use take
  none);
- a type of the module, or of another Bea module of the project: that
  module's `<type>_<deriver>`, derived (`users.user_decoder()`) or written
  by hand, which is how a union, a recursive or an external type joins in;
- a type alias: what it stands for (for another module's alias, when it
  only names the prelude and the standard library: `pub type Id = String`);
- any other type: the deriver's own, named after it: `decoder.int()`,
  `decoder.list(decoder.string())`, `decoder.option(...)`,
  `decoder.dict(k, v)`, `decoder.timestamp()`. If the deriver has none,
  Gleam says so on the field:

```text
error: Unknown module value
  ┌─ src/app/events.bea:6:27
  │
6 │   Event(name: String, at: Timestamp)
  │                           ^^^^^^^^^

The module `my_json/decoder` does not have a `timestamp` value.
```

**Writing a deriver.** A deriver exports `record`, `field` and `done`, and
a function per type it supports. The derived function reads, with `use`:
`record(constructor_name, fields)` makes the result from the fields (a
function, called when the deriver wants); `field(label, part, get, next)`
handles one field — `get` reads it from a record, `next` continues with its
value; `done(record)` ends the fields. Decoders use `next`, encoders `get`;
everything else (names, missing fields, `null`, numbers, errors, what
`record` returns) is the deriver's choice:

```bea
//// my_json/decoder.bea: derived decoders are standard `decode.Decoder`s.
import gleam/dynamic/decode.{type Decoder}

pub def record(_name: String, fields: fn() -> Decoder(r)) -> Decoder(r) {
  fields()
}

pub def field(label: String, of: Decoder(a), _get: fn(r) -> a, next: fn(a) -> Decoder(r)) -> Decoder(r) {
  decode.field(label, of, next)
}

pub def done(value: r) -> Decoder(r) {
  decode.success(value)
}

pub def string() -> Decoder(String) {
  decode.string
}
// int, float, bool, list, option, dict...
```

`test_projects/deriving` has complete derivers for JSON decoding and
encoding, and one for HTML forms written in Gleam.

**For now** only records are derived (one constructor, labelled fields, not
recursive); other types are reported, and their function can be written by
hand. `@derive` goes on a `type`, and names imported modules.

### Functions through their type

A type's functions are named after it, `<type>_<name>`: what `@derive`
defines (`credentials_decoder`), and what you write by hand for a type
that can't be derived (`role_decoder` for a union). `Type.name` is that
function, reached through the type:

```bea
import app/auth
import app/users.{type User}

Credentials.decoder()               // credentials_decoder(), of this module
User.decoder()                      // users.user_decoder()
users.Page.decoder(User.decoder())  // users.page_decoder(users.user_decoder())
auth.Credentials.form()             // auth.credentials_form()
Credentials.decoder                 // the function itself, as a value
```

Importing a type (`{type User}`, also `{type User as U}`) brings its
functions along, whatever its module is called in the file; when the type
was imported only for them, the Gleam doesn't import it. The type's name is
written as it is, so `HTTPRequest.decoder()` needs no thought about how
`http_request_decoder` is spelled.

This is only naming. The Gleam is the same as with the name written out,
so Gleam code and other packages call `credentials_decoder` as always, and
both spellings work in Bea. It is not a method: `creds.encode()` would need
the type of `creds`, which only Gleam's type checker knows, so functions
belong to types, not to values. Bea reports what it can see:

- `Credentials.encoder()` without the function in the module: *Unknown
  function*, with the `@derive(encoder)` to add;
- a constructor of another type (`Circle.area()`): *Not a type*, pointing
  to `Shape.area`;
- `String.length("x")`: *Unknown type*, pointing to `string.length`;
- a variable called `credentials_decoder` (or one called like the type's
  module) in scope: *Shadowed function*, since Gleam couldn't reach the
  function past it.

For types of other modules, Gleam checks that the function exists.

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
- `bea docs` isn't implemented; run `gleam docs build` inside `.beabuild/`
  if you need it. Tests are Gleam modules (`bea test` runs them); test
  modules written in Bea aren't supported yet.
- Path dependencies (`{ path = "..." }`) are resolved from `.beabuild/`, so
  relative paths need a `../` (or use an absolute path).
- Tools that compile the project themselves by running `gleam build` in the
  current directory don't understand `.bea` files; tools that only use their
  own code and the project's files (like Marmot) work.

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
  onto the right Gleam token), also while the construct is still being
  written (`case x|` before its `{`, a clause guard or `cond` condition
  before its `->`, `if x|` before its block); in `case` patterns, completion
  of constructors
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
.bea ──lexer──▶ tokens ──parser──▶ AST ──deriving──▶ AST ──lower──▶ AST ──codegen──▶ .gleam + source map
                (spans,            (Pratt,         (@derive          (cond, ?,         (pretty printer
                 comments)          recovery)       → functions,      returns,          with marks)
                                                    Type.f → f)       clauses)
```

The compiler is written in Bea: these modules are in `src/`, and the
repository is a Bea project like any other, built by a `bea`
([docs/self-hosting.md](docs/self-hosting.md)).

| Module | Role |
| --- | --- |
| `bea/lexer` | Byte-based lexer with exact spans; keeps comments; string interpolation |
| `bea/parser` | Recursive descent + precedence climbing (Gleam's table); error recovery per definition |
| `bea/ast` | Syntax tree, every node has a span |
| `bea/deriving` | `@derive(m)` on a record → ordinary functions calling the deriver module `m` |
| `bea/associated` | `Type.name` → the function `<type>_<name>` it names (scope aware), in the module or through the type's import |
| `bea/lower` | `cond` → `if`, `else` guards → `case`, `?` hoisting (tail-aware), early returns → guards/continuations, multi-clause → `case` |
| `bea/codegen` | Gleam printer, scope-aware import planning, `let` vs `let assert` |
| `bea/doc` | Wadler-style pretty printer that records source mappings |
| `bea/sourcemap` | Bea ↔ Gleam position translation |
| `bea/formatter` | Bea formatter with comment anchoring and a parse-back safety check |
| `bea/imports` | Organising imports: grouping, sorting, removing unused ones, adding obvious ones |
| `bea/project` | Project discovery, `.beabuild` sync, manifest handling, compile cache |
| `bea/gleam_output` | Rewrites Gleam CLI output to Bea locations |
| `bea/cli` | The `bea` command |
| `bea/entrypoint` | `bea run`: its arguments, finding the module to run (in the project or a dependency), tool configuration |
| `bea/pack` | `bea pack`: its options, where the executable goes, finding and running gleepack |
| `bea/style`, `bea/highlight` | The CLI's colours, and syntax highlighting of Bea and Gleam |
| `bea/shell`, `bea/line_editor` | `bea shell`: Bea front end for GSH's evaluator, and its line editor |
| `bea/lsp/*` | JSON, JSON-RPC transport, the proxying language server |
| `bea/lsp/repair` | Makes the buffer being typed compile (placeholder, closing brackets), finds the call around the cursor |
| `bea/lsp/index` | Public API of the project and its dependencies (parameter names, docs, unimported values), FFI lookup |
| `bea_signal`, `bea_ffi` | Ctrl+C forwarding, child processes with a watchdog |

## Development

Bea is written in Bea, and this repository is an ordinary Bea project
(`bea.toml`, the compiler in `src/`, Gleam tests in `test/`): building it
needs a `bea`, such as the binary from the
[releases](https://github.com/the-bea-project/bea/releases) page or one you
built before. [docs/self-hosting.md](docs/self-hosting.md) explains how it
builds itself, and how to build it without any `bea` at all.

```sh
bea build                       # an installed bea builds the compiler into .beabuild/
scripts/bea build               # ... which rebuilds itself (scripts/bea runs the checkout's build)
scripts/bea test                # unit tests, with the compiler just built
export PATH=$PWD/scripts:$PATH  # from here on, `bea` is this checkout's compiler
scripts/test_examples.sh        # fixtures, exercism examples, formatter, via the CLI
scripts/test_tooling.sh         # bea run -m with Gleam tools, generated code, bea pack, bea test (BEA_TEST_MARMOT=1: also Marmot; BEA_TEST_GLEEPACK=1: also gleepack)
python3 test/lsp/test_lsp.py    # language server integration test
python3 test/cli/test_interrupt.py  # Ctrl+C in `bea run` leaves the terminal alone
bea pack                        # the compiler as a standalone executable, build/bea (needs gleepack)
```

`scripts/bea build` is what makes a change to the compiler's code
generation reach the compiler itself: the first build is compiled by the
`bea` you had, the second by the new compiler.

`beacode/` holds Bea solutions to the Gleam exercism track; `test/fixtures/`
holds programs with expected output that cover the remaining exercism concepts
(let assertions, bit arrays, IO/Nil, opaque and phantom types, external
functions, `use`) and Bea's own features.
