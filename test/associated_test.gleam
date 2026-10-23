//// `Type.name`: the function `<type>_<name>` reached through its type, such
//// as `Credentials.decoder()` for what `@derive(decoder)` defines.

import bea/codegen
import bea/compiler
import bea/formatter
import bea/imports
import bea/project
import bea/system
import gleam/dict
import gleam/list
import gleam/option
import gleam/string
import simplifile

fn gleam(source: String) -> String {
  let assert Ok(compiled) = compiler.compile(source, codegen.empty_context())
  compiled.gleam
}

fn errors(source: String) -> List(#(String, String)) {
  let assert Error(diags) = compiler.compile(source, codegen.empty_context())
  list.map(diags, fn(d) { #(d.title, d.label) })
}

fn titles(source: String) -> List(String) {
  errors(source) |> list.map(fn(e) { e.0 })
}

const credentials = "import my_json/decoder

@derive(decoder)
pub type Credentials {
  Credentials(username: String, password: String)
}
"

pub fn derived_function_through_its_type_test() {
  let out = gleam(credentials <> "
pub def login(body: String) {
  decoder.from_json(body, Credentials.decoder())
}
")
  assert string.contains(out, "decoder.from_json(body, credentials_decoder())")
  // The same Gleam as before: the derived function keeps its name.
  assert string.contains(out, "pub fn credentials_decoder() {")
}

pub fn as_a_value_test() {
  let out = gleam(credentials <> "
pub def decoders() {
  [Credentials.decoder]
}

pub def piped(body) {
  body |> Credentials.decoder |> decoder.from_json
}
")
  assert string.contains(out, "[credentials_decoder]")
  assert string.contains(
    out,
    "body |> credentials_decoder |> decoder.from_json",
  )
}

pub fn hand_written_functions_too_test() {
  // The convention, not `@derive`: a union's decoder written by hand.
  let out =
    gleam(
      "pub type Role {
  Admin
  Member
}

pub def role_decoder() {
  decode.string
}

pub def go() {
  Role.decoder()
}
",
    )
  assert string.contains(out, "  role_decoder()\n")
}

pub fn generic_types_take_their_arguments_test() {
  let out =
    gleam(
      "import my_json/decoder

@derive(decoder)
pub type Page(item) {
  Page(items: List(item), total: Int)
}

@derive(decoder)
pub type User {
  User(name: String)
}

pub def go() {
  Page.decoder(User.decoder())
}
",
    )
  assert string.contains(out, "page_decoder(user_decoder())")
}

pub fn names_follow_the_deriver_and_the_type_test() {
  // `import ... as json` derives `credentials_json`: `Credentials.json()`.
  let out =
    gleam(
      "import my_json/decoder as json

@derive(json)
pub type HTTPRequest {
  HTTPRequest(path: String)
}

pub def go() {
  HTTPRequest.json()
}
",
    )
  assert string.contains(out, "  http_request_json()\n")
}

pub fn types_of_other_modules_test() {
  let out =
    gleam(
      "import app/auth
import app/users.{type User}
import app/orders.{type Order as O} as o

pub def go() {
  (auth.Credentials.decoder(), User.decoder(), O.encoder(), o.Cart.decoder())
}
",
    )
  assert string.contains(out, "auth.credentials_decoder()")
  // An imported type brings its functions along, whatever its module is
  // called here and whatever the type is called here.
  assert string.contains(out, "users.user_decoder()")
  assert string.contains(out, "o.order_encoder()")
  assert string.contains(out, "o.cart_decoder()")
  // The type imports were only there for `Type.name`, so Gleam doesn't
  // see them (it would warn that they are unused).
  assert string.contains(out, "import app/users\n")
  assert string.contains(out, "import app/orders as o\n")
}

pub fn type_imports_still_used_are_kept_test() {
  let out =
    gleam(
      "import app/users.{type User}

pub def go() -> User {
  User.decoder()
}
",
    )
  assert string.contains(out, "import app/users.{type User}")
  assert string.contains(out, "users.user_decoder()")
}

pub fn everywhere_an_expression_goes_test() {
  let out = gleam(credentials <> "
pub const all = [Credentials.decoder]

pub def go(xs, body) {
  f = fn(b) { decoder.from_json(b, Credentials.decoder()) }
  case xs {
    [] -> decoder.from_json(body, Credentials.decoder())
    _ -> {
      d = Credentials.decoder()
      decoder.from_json(\"#{body}\", d)
    }
  }
}
")
  assert !string.contains(out, "Credentials.decoder")
  assert string.contains(out, "pub const all = [credentials_decoder]")
}

// --- Errors ----------------------------------------------------------------------

pub fn not_defined_test() {
  assert errors(credentials <> "
pub def go() {
  Credentials.encoder()
}
") == [
      #(
        "Unknown function",
        "`Credentials` has no `encoder`: this module defines no `credentials_encoder`",
      ),
    ]
}

pub fn a_failed_derive_is_reported_once_test() {
  // The error is the derive's, not the call's.
  assert titles(
      "import my_json/decoder

@derive(decoder)
pub type Shape {
  Circle(r: Float)
  Square(side: Float)
}

pub def go() {
  Shape.decoder()
}
",
    )
    == ["Cannot derive for `Shape`"]
}

pub fn constructors_are_not_types_test() {
  assert errors(
      "pub type Shape {
  Circle(r: Float)
}

pub def go() {
  Circle.area()
}
",
    )
    == [#("Not a type", "`Circle` is a constructor of `Shape`")]
}

pub fn unknown_types_test() {
  let source =
    "pub def go() {
  String.length(\"bea\")
}
"
  let assert Error([d]) = compiler.compile(source, codegen.empty_context())
  assert d.title == "Unknown type"
  assert d.hint
    == option.Some(
      "The standard library's functions for `String` are in its module: `string.length`.",
    )
}

pub fn shadowing_is_reported_test() {
  assert titles(credentials <> "
pub def go(credentials_decoder) {
  Credentials.decoder()
}
") == ["Shadowed function"]
  assert titles(
      "import app/users.{type User}

pub def go() {
  users = 1
  User.decoder()
}
",
    )
    == ["Shadowed module"]
  // A variable only shadows what comes after it.
  let out = gleam(credentials <> "
pub def go() {
  d = Credentials.decoder()
  credentials_decoder = d
  credentials_decoder
}
")
  assert string.contains(out, "let d = credentials_decoder()")
}

// --- Tooling ---------------------------------------------------------------------

pub fn formatter_keeps_it_test() {
  let source =
    "import app/users.{type User}

pub def go() {
  (User.decoder(), users.Page.decoder(User.decoder()))
}
"
  assert formatter.format(source) == Ok(source)
}

pub fn organising_imports_keeps_the_type_test() {
  // `bea format --imports` must not drop a type import `Type.name` uses.
  let source =
    "import app/users.{type Other, type User}

pub def go() {
  User.decoder()
}
"
  assert imports.organize(source, imports.nothing_known())
    == string.replace(source, "type Other, ", "")
}

fn fresh_project(name: String) -> project.Project {
  let root = system.absolute_path("build/bea_test_projects/" <> name)
  let _ = simplifile.delete(root)
  let assert Ok(_) = simplifile.create_directory_all(root <> "/src/app")
  let assert Ok(_) =
    simplifile.write(root <> "/bea.toml", project.default_config(name))
  let assert Ok(p) = project.find(root)
  p
}

pub fn across_the_project_test() {
  let p = fresh_project("associated_functions")
  let assert Ok(_) =
    simplifile.write(
      p.src_dir <> "/app/users.bea",
      "import my_json/decoder as json

@derive(json)
pub type User {
  User(name: String)
}
",
    )
  let assert Ok(_) =
    simplifile.write(
      p.src_dir <> "/app/main.bea",
      "import app/users.{type User}

pub def go() {
  User.json()
}
",
    )
  let s = project.sync(p, dict.new())
  assert s.errors == []
  let assert Ok(out) = simplifile.read(p.build_dir <> "/src/app/main.gleam")
  assert string.contains(out, "users.user_json()")
}
