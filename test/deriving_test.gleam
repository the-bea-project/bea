//// `@derive`: functions written from a record's structure by a deriver
//// module. These tests check the Gleam that is generated and the
//// diagnostics; test_projects/deriving runs real derivers (JSON decoding and
//// encoding, HTML forms) end to end.

import bea/codegen
import bea/compiler
import bea/deriving
import bea/formatter
import bea/imports
import bea/lsp/index
import bea/parser
import bea/project
import bea/system
import gleam/dict
import gleam/int
import gleam/list
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
import my_json/encoder

@derive(decoder)
pub type Credentials {
  Credentials(
    username: String,
    password: String,
  )
}
"

// --- The generated functions ---------------------------------------------------------

pub fn record_test() {
  let out = gleam(credentials)
  assert string.contains(
    out,
    "/// Derived by `@derive(decoder)` on `Credentials`.
pub fn credentials_decoder() {
  use <- decoder.record(\"Credentials\")
  use username <- decoder.field(
    \"username\",
    decoder.string(),
    fn(value: Credentials) { value.username },
  )
  use password <- decoder.field(
    \"password\",
    decoder.string(),
    fn(value: Credentials) { value.password },
  )
  decoder.done(Credentials(username: username, password: password))
}",
  )
  // The attribute is Bea's: Gleam never sees it.
  assert !string.contains(out, "\n@derive")
  assert string.contains(out, "pub type Credentials {")
  // Only what was asked for: no encoder.
  assert !string.contains(out, "credentials_encoder")
}

pub fn several_derivers_are_independent_test() {
  let out =
    gleam(string.replace(
      credentials,
      "@derive(decoder)",
      "@derive(decoder, encoder)",
    ))
  assert string.contains(out, "pub fn credentials_decoder() {")
  assert string.contains(out, "pub fn credentials_encoder() {")
  assert string.contains(out, "use <- encoder.record(\"Credentials\")")
  assert string.contains(out, "encoder.done(Credentials(")
}

pub fn derived_functions_follow_the_type_test() {
  let out =
    gleam(
      "import d
@derive(d)
pub type Credentials { Credentials(username: String) }
pub def main() { credentials_d() }",
    )
  // Right after the type, before what follows it.
  let assert [_, after_type] = string.split(out, "pub type Credentials {")
  let assert [before_main, _] = string.split(after_type, "pub fn main()")
  assert string.contains(before_main, "pub fn credentials_d()")
}

pub fn visibility_test() {
  let out =
    gleam(
      "import d
@derive(d)
pub type A { A(x: Int) }
@derive(d)
type B { B(x: Int) }
@derive(d)
pub opaque type C { C(x: Int) }",
    )
  assert string.contains(out, "pub fn a_d() {")
  assert string.contains(out, "\nfn b_d() {")
  // An opaque type's constructor is private, and so is what uses it.
  assert string.contains(out, "\nfn c_d() {")
}

pub fn deriver_types_by_name_test() {
  let out =
    gleam(
      "import d
import gleam/time/timestamp
@derive(d)
pub type T {
  T(
    a: Int,
    b: List(Float),
    c: Option(Bool),
    d: Dict(String, BitArray),
    e: timestamp.Timestamp,
    f: Result(Nil, UtfCodepoint),
  )
}",
    )
  assert string.contains(out, "d.int(),")
  assert string.contains(out, "d.list(d.float()),")
  assert string.contains(out, "d.option(d.bool()),")
  assert string.contains(out, "d.dict(d.string(), d.bit_array()),")
  assert string.contains(out, "d.timestamp(),")
  assert string.contains(out, "d.result(d.nil(), d.utf_codepoint()),")
  assert string.contains(out, "import gleam/option.{type Option}")
}

pub fn snake_case_test() {
  assert deriving.snake_case("Credentials") == "credentials"
  assert deriving.snake_case("BitArray") == "bit_array"
  assert deriving.snake_case("HTTPRequest") == "http_request"
  assert deriving.snake_case("UserV2") == "user_v2"
  assert deriving.function_name("FindUserRow", "decoder")
    == "find_user_row_decoder"
}

pub fn nested_local_records_test() {
  let out =
    gleam(
      "import d
@derive(d)
pub type Address { Address(city: String) }
@derive(d)
pub type User { User(home: Address, past: List(Address)) }",
    )
  assert string.contains(out, "address_d(),")
  assert string.contains(out, "d.list(address_d()),")
}

pub fn generic_types_test() {
  let out =
    gleam(
      "import d
@derive(d)
pub type Page(item) { Page(items: List(item), total: Int) }
@derive(d)
pub type Users { Users(page: Page(String)) }",
    )
  assert string.contains(out, "pub fn page_d(item_d) {")
  assert string.contains(out, "d.list(item_d),")
  assert string.contains(out, "fn(value: Page(item)) { value.items }")
  assert string.contains(out, "page_d(d.string()),")
}

pub fn phantom_parameters_take_nothing_test() {
  let out =
    gleam(
      "import d
pub type Eur
@derive(d)
pub type Price(currency) { Price(cents: Int) }
@derive(d)
pub type Wrapped(c) { Wrapped(price: Price(c)) }
@derive(d)
pub type Product { Product(price: Price(Eur), wrapped: Wrapped(Eur)) }",
    )
  assert string.contains(out, "pub fn price_d() {")
  // Its parameter is only given to a phantom one: no argument either.
  assert string.contains(out, "pub fn wrapped_d() {")
  assert string.contains(out, "price_d(),")
  assert string.contains(out, "wrapped_d(),")
  assert !string.contains(out, "d.eur")
}

pub fn type_aliases_are_expanded_test() {
  let out =
    gleam(
      "import d
type Tags = List(String)
type Pairs(v) = Dict(String, v)
@derive(d)
pub type Post { Post(tags: Tags, counts: Pairs(Int)) }",
    )
  assert string.contains(out, "d.list(d.string()),")
  assert string.contains(out, "d.dict(d.string(), d.int()),")
}

pub fn hand_written_functions_take_every_parameter_test() {
  // Even one the type's fields don't use.
  let out =
    gleam(
      "import d
pub type Tagged(tag) { Tagged(id: Int) }
pub def tagged_d(tag_d) { todo }
@derive(d)
pub type Note(t) { Note(tagged: Tagged(t)) }",
    )
  assert string.contains(out, "pub fn note_d(t_d) {")
  assert string.contains(out, "tagged_d(t_d),")
}

pub fn hand_written_function_with_a_phantom_parameter_test() {
  let out =
    gleam(
      "import d
pub type Inner(a) { Inner(n: Int) }
pub def inner_d(_a) { todo }
@derive(d)
pub type Outer(x) { Outer(i: Inner(x)) }",
    )
  assert string.contains(out, "pub fn outer_d(x_d) {")
  assert string.contains(out, "inner_d(x_d),")
}

pub fn hand_written_function_for_an_external_type_test() {
  let out =
    gleam(
      "import d
pub type Ext
pub def ext_d() { todo }
@derive(d)
pub type T { T(e: Ext) }",
    )
  assert string.contains(out, "ext_d(),")
}

pub fn hand_written_functions_are_used_test() {
  // A union can't be derived, but its function can be written by hand.
  let out =
    gleam(
      "import d
pub type Status { Active Banned(reason: String) }
pub def status_d() { todo }
@derive(d)
pub type Account { Account(status: Status, history: List(Status)) }",
    )
  assert string.contains(out, "status_d(),")
  assert string.contains(out, "d.list(status_d()),")
}

pub fn labels_never_shadow_what_later_fields_use_test() {
  let out =
    gleam(
      "import d
@derive(d)
pub type Address { Address(city: String) }
@derive(d)
pub type User { User(d: Int, address_d: String, home: Address) }",
    )
  assert string.contains(out, "use d_ <- d.field(")
  assert string.contains(out, "use address_d_ <- d.field(")
  assert string.contains(out, "address_d(),")
  assert string.contains(
    out,
    "d.done(User(d: d_, address_d: address_d_, home: home))",
  )
}

pub fn empty_record_test() {
  let out = gleam("import d\n@derive(d)\npub type Ping { Ping }")
  assert string.contains(out, "use <- d.record(\"Ping\")\n  d.done(Ping)\n}")
}

pub fn aliased_deriver_test() {
  // The function is named after the deriver as the module calls it.
  let out =
    gleam(
      "import some/json/decoder as json_decoder
@derive(json_decoder)
pub type Credentials { Credentials(username: String) }",
    )
  assert string.contains(out, "pub fn credentials_json_decoder() {")
  assert string.contains(out, "json_decoder.field(")
}

pub fn no_module_is_special_test() {
  // `decode` is an ordinary module here: it is imported like any other
  // (Gleam then reports that it has no `record`).
  let out = gleam("@derive(decode)\npub type P { P(x: Int) }")
  assert string.contains(out, "import gleam/dynamic/decode")
  assert string.contains(out, "use <- decode.record(\"P\")")
  assert string.contains(out, "decode.int(),")
}

pub fn other_attributes_still_go_to_gleam_test() {
  let out =
    gleam(
      "import d
@deprecated(\"use V2\")
@derive(d)
pub type V1 { V1(x: Int) }",
    )
  assert string.contains(out, "@deprecated(\"use V2\")\npub type V1")
}

pub fn derive_is_only_reserved_as_a_name_test() {
  assert titles("pub def f() {\n  derive = 1\n  derive\n}")
    == ["Reserved word", "Reserved word"]
  assert titles("@macro\npub def f() { 1 }") == ["Reserved word"]
}

// --- Diagnostics ---------------------------------------------------------------------

pub fn unknown_deriver_test() {
  assert errors("@derive(decoder)\npub type P { P(x: Int) }")
    == [#("Unknown deriver", "`decoder` is not an imported module")]
}

pub fn invalid_derive_arguments_test() {
  assert titles(
      "import d
@derive
pub type A { A(x: Int) }
@derive(\"d\")
pub type B { B(x: Int) }
@derive(d, d)
pub type C { C(x: Int) }",
    )
    == ["Empty derive", "Invalid deriver", "Duplicate deriver"]
}

pub fn unions_are_not_derived_test() {
  assert errors(
      "import d\n@derive(d)\npub type Shape { Circle(r: Float) Square(s: Float) }",
    )
    == [
      #(
        "Cannot derive for `Shape`",
        "`Shape` has 2 constructors; only records (one constructor) can be derived for now",
      ),
    ]
  assert titles("import d\n@derive(d)\npub type Never {}")
    == ["Nothing to derive"]
}

pub fn unlabelled_fields_test() {
  assert titles("import d\n@derive(d)\npub type Point { Point(Int, y: Int) }")
    == ["Unlabelled field"]
}

pub fn unsupported_field_types_test() {
  assert errors(
      "import d
@derive(d)
pub type T { T(pair: #(Int, Int), f: fn(Int) -> Int) }",
    )
    == [
      #(
        "Unsupported field type",
        "a field whose type is a tuple can't be derived",
      ),
      #(
        "Unsupported field type",
        "a field whose type is a function can't be derived",
      ),
    ]
  assert titles(
      "import d
pub type Usd
@derive(d)
pub type Money { Money(currency: Usd) }",
    )
    == ["Missing derive"]
}

pub fn missing_derive_test() {
  assert errors(
      "import d
pub type Address { Address(city: String) }
@derive(d)
pub type User { User(home: Address) }",
    )
    == [#("Missing derive", "`Address` doesn't derive `d`")]
  // The same deriver: deriving another one doesn't count.
  assert titles(
      "import d
import e
@derive(e)
pub type Address { Address(city: String) }
@derive(d)
pub type User { User(home: Address) }",
    )
    == ["Missing derive"]
}

pub fn recursive_types_test() {
  assert titles(
      "import d
@derive(d)
pub type Tree { Tree(value: Int, children: List(Tree)) }",
    )
    == ["Recursive type"]
  assert titles(
      "import d
@derive(d)
pub type Ping { Ping(pong: Option(Pong)) }
@derive(d)
pub type Pong { Pong(ping: Ping) }",
    )
    == ["Recursive type", "Recursive type"]
}

pub fn recursion_is_reported_where_it_is_test() {
  // Only `Z` is recursive: `M` and `T` merely contain it.
  assert errors(
      "import d
@derive(d)
type Z { Z(z: Option(Z)) }
@derive(d)
type M { M(z: Z) }
@derive(d)
pub type T { T(m: M) }",
    )
    == [
      #(
        "Recursive type",
        "`Z` contains itself through this field; recursive types can't be derived yet",
      ),
    ]
}

pub fn recursive_aliases_test() {
  // Gleam rejects them; deriving must not loop on them meanwhile.
  assert titles(
      "import d
type A = List(A)
@derive(d)
pub type T { T(a: A) }",
    )
    == ["Recursive type alias"]
}

pub fn alias_arguments_test() {
  assert titles(
      "import d
type P(a) = List(a)
@derive(d)
pub type T { T(p: P) }",
    )
    == ["Wrong number of type arguments"]
}

pub fn deep_nesting_is_fast_test() {
  // Every type has three fields of the next one: the analysis must not
  // follow every path (3^30 of them).
  let types =
    int.range(from: 1, to: 31, with: [], run: fn(acc, i) { [i, ..acc] })
    |> list.reverse
    |> list.map(fn(i) {
      let next = "T" <> int.to_string(i + 1)
      "@derive(d)\npub type T"
      <> int.to_string(i)
      <> "(a) { T"
      <> int.to_string(i)
      <> "(x: "
      <> next
      <> "(a), y: "
      <> next
      <> "(a), z: List("
      <> next
      <> "(a))) }"
    })
  let source =
    "import d\n"
    <> string.join(types, "\n")
    <> "\n@derive(d)\npub type T31(a) { T31(v: a) }"
  let out = gleam(source)
  assert string.contains(out, "pub fn t1_d(a_d) {")
  assert string.contains(out, "t2_d(a_d),")
}

pub fn name_clashes_test() {
  assert titles(
      "import d
@derive(d)
pub type User { User(x: Int) }
pub def user_d() { 1 }",
    )
    == ["Duplicate definition"]
}

pub fn derive_on_anything_else_test() {
  assert titles(
      "import d
@derive(d)
pub def f() { 1 }
@derive(d)
type Alias = Int",
    )
    == ["Nothing to derive", "Nothing to derive"]
}

pub fn several_errors_in_source_order_test() {
  let errs =
    compiler.compile(
      "import d
@derive(d)
pub type A { A(x: #(Int, Int)) }
@derive(nope)
pub type B { B(x: Int) }",
      codegen.empty_context(),
    )
  let assert Error([first, second]) = errs
  assert first.title == "Unsupported field type"
  assert second.title == "Unknown deriver"
  assert first.span.start < second.span.start
}

// --- Across modules ------------------------------------------------------------------

fn fresh_project(name: String) -> project.Project {
  let root = system.absolute_path("build/bea_test_projects/" <> name)
  let _ = simplifile.delete(root)
  let assert Ok(_) = simplifile.create_directory_all(root <> "/src/app")
  let assert Ok(_) =
    simplifile.write(root <> "/bea.toml", project.default_config(name))
  let assert Ok(p) = project.find(root)
  p
}

pub fn fields_from_other_modules_test() {
  let p = fresh_project("deriving_modules")
  let assert Ok(_) =
    simplifile.write(
      p.src_dir <> "/app/users.bea",
      "import my_json/decoder as json

pub type Eur

@derive(json)
pub type Price(currency) {
  Price(cents: Int)
}

@derive(json)
pub type Page(item) {
  Page(items: List(item))
}

@derive(json)
pub type User {
  User(name: String)
}

pub type Role {
  Admin
  Member
}

@derive(json)
type Hidden {
  Hidden(x: Int)
}
",
    )
  let assert Ok(_) =
    simplifile.write(
      p.src_dir <> "/app/orders.bea",
      "import app/users.{type User}
import gleam/time/timestamp
import my_json/decoder

@derive(decoder)
pub type Order {
  Order(
    customer: User,
    pages: users.Page(users.Price(users.Eur)),
    role: users.Role,
    at: timestamp.Timestamp,
  )
}
",
    )
  let s = project.sync(p, dict.new())
  assert s.errors == []
  // What other modules learn: public types only, by deriver module.
  assert dict.get(s.context.derived, "app/users")
    == Ok([
      codegen.Derived("Price", "my_json/decoder", "price_json", [False], True),
      codegen.Derived("Page", "my_json/decoder", "page_json", [True], True),
      codegen.Derived("User", "my_json/decoder", "user_json", [], True),
    ])
  let assert Ok(out) = simplifile.read(p.build_dir <> "/src/app/orders.gleam")
  // The other module's derived functions, whatever it calls the deriver.
  assert string.contains(out, "users.user_json(),")
  assert string.contains(out, "users.page_json(users.price_json()),")
  // Not derived there: by name, it may be written by hand (Gleam checks).
  assert string.contains(out, "users.role_decoder(),")
  // Not a module of the project: the deriver's.
  assert string.contains(out, "decoder.timestamp(),")
}

pub fn aliases_from_other_modules_test() {
  let p = fresh_project("deriving_aliases")
  let assert Ok(_) =
    simplifile.write(
      p.src_dir <> "/app/ids.bea",
      "import d

pub type Id = String
pub type Wrap(a) = List(a)
pub type User { User(id: Id) }
// Names a type of this module: not the same elsewhere.
pub type Users = List(User)

@derive(d)
pub opaque type Secret {
  Secret(value: String)
}
",
    )
  let assert Ok(_) =
    simplifile.write(
      p.src_dir <> "/app/main.bea",
      "import app/ids.{type Id}
import d

@derive(d)
pub type T {
  T(id: Id, ids: ids.Wrap(ids.Id), users: ids.Users)
}
",
    )
  let s = project.sync(p, dict.new())
  assert s.errors == []
  let assert Ok(out) = simplifile.read(p.build_dir <> "/src/app/main.gleam")
  assert string.contains(out, "d.string(),")
  assert string.contains(out, "d.list(d.string()),")
  assert string.contains(out, "ids.users_d(),")

  // An opaque type's derived functions are private to its module.
  let assert Ok(_) =
    simplifile.write(
      p.src_dir <> "/app/main.bea",
      "import app/ids
import d

@derive(d)
pub type T {
  T(secret: ids.Secret)
}
",
    )
  let s = project.sync(p, dict.new())
  let assert [project.FileErrors(diagnostics: [error], ..)] = s.errors
  assert error.title == "Private derived function"
}

// --- Tooling -------------------------------------------------------------------------

pub fn formatter_keeps_derive_test() {
  let source =
    "import my_json/decoder
import my_json/encoder

@derive(decoder, encoder)
pub type Credentials {
  Credentials(username: String, password: String)
}
"
  assert formatter.format(source) == Ok(source)
}

pub fn deriver_imports_are_used_test() {
  // `bea format --imports` must not drop an import only `@derive` uses.
  let source =
    "import my_json/decoder
import my_json/unused

@derive(decoder)
pub type Credentials {
  Credentials(username: String)
}
"
  assert imports.organize(source, imports.nothing_known())
    == string.replace(source, "import my_json/unused\n", "")
}

pub fn language_server_index_test() {
  // Completion of derived functions, also from modules not imported yet.
  let parsed = parser.parse_module(credentials).module
  let entries = index.from_bea("app/auth", parsed)
  let assert Ok(entry) =
    list.find(entries, fn(e) { e.name == "credentials_decoder" })
  assert entry.kind == index.Function
  assert entry.params == []
}
