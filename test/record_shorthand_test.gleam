//// Records: `pub type AuthToken { sub: String, role: String }` is exactly
//// `pub type AuthToken { AuthToken(sub: String, role: String) }`, and
//// `pub type Page(item) { items: List(item) }` exactly
//// `pub type Page(item) { Page(items: List(item)) }`. The parser desugars a
//// record into the same syntax tree, so everything after parsing (deriving,
//// associated functions, lowering, code generation) is shared; only the
//// formatter looks at which form was written.

import bea/ast
import bea/codegen
import bea/compiler
import bea/formatter
import bea/parser
import bea/span
import gleam/list
import gleam/option.{Some}
import gleam/regexp
import gleam/string

/// The module's items with every position erased.
fn shape(source: String) -> String {
  let result = parser.parse_module(source)
  let assert [] = result.errors
  let assert Ok(re) = regexp.from_string("Span\\(\\d+, \\d+\\)")
  regexp.replace(re, string.inspect(result.module), "Span")
}

fn items(source: String) -> List(ast.Item) {
  let result = parser.parse_module(source)
  let assert [] = result.errors
  result.module.items
}

fn parse_errors(source: String) -> List(String) {
  parser.parse_module(source).errors |> list.map(fn(d) { d.title })
}

fn gleam(source: String) -> String {
  let assert Ok(compiled) = compiler.compile(source, codegen.empty_context())
  compiled.gleam
}

fn format(source: String) -> String {
  let assert Ok(out) = formatter.format(source)
  out
}

/// Pairs of a record and the long form it stands for.
const equivalents = [
  #(
    "pub type AuthToken { sub: String, role: String }",
    "pub type AuthToken {\n  AuthToken(sub: String, role: String)\n}",
  ),
  #(
    "type Point {\n  x: Float,\n  y: Float,\n}",
    "type Point {\n  Point(x: Float, y: Float)\n}",
  ),
  #(
    "pub opaque type Email { address: String }",
    "pub opaque type Email {\n  Email(address: String)\n}",
  ),
  #(
    "pub type Page(item) { items: List(item), total: Int }",
    "pub type Page(item) {\n  Page(items: List(item), total: Int)\n}",
  ),
  #(
    "pub type Pair(a, b) { first: a, second: b }",
    "pub type Pair(a, b) {\n  Pair(first: a, second: b)\n}",
  ),
  #(
    "pub type Rich {\n  at: time.Timestamp,\n  xs: List(Int),\n  f: fn(Int) -> String,\n  pair: #(Int, String),\n  t: (Int, Bool),\n}",
    "pub type Rich {\n  Rich(at: time.Timestamp, xs: List(Int), f: fn(Int) -> String, pair: #(Int, String), t: (Int, Bool))\n}",
  ),
  #(
    "pub type Labels { return: Int, and: Bool }",
    "pub type Labels {\n  Labels(return: Int, and: Bool)\n}",
  ),
  #(
    "/// A token.\n@derive(decoder)\n@deprecated(\"use Other\")\npub type T { a: Int }",
    "/// A token.\n@derive(decoder)\n@deprecated(\"use Other\")\npub type T {\n  T(a: Int)\n}",
  ),
]

// --- Parser ----------------------------------------------------------------------

pub fn record_parses_like_the_long_form_test() {
  list.each(equivalents, fn(pair) {
    let #(short, long) = pair
    assert shape(short) == shape(long)
  })
}

pub fn record_keeps_visibility_fields_params_and_docs_test() {
  let assert [
    ast.CustomType(
      doc: [" A token."],
      attributes: [ast.Attribute(name: "derive", ..)],
      publicity: ast.Public,
      opaque_: False,
      name: "AuthToken",
      params: [],
      variants: [
        ast.Variant(
          name: "AuthToken",
          fields: [
            ast.Field(
              label: Some("sub"),
              type_: ast.NamedType(name: "String", ..),
              ..,
            ),
            ast.Field(
              label: Some("role"),
              type_: ast.NamedType(name: "String", ..),
              ..,
            ),
          ],
          doc: [],
          ..,
        ),
      ],
      ..,
    ),
  ] =
    items(
      "/// A token.\n@derive(decoder)\npub type AuthToken { sub: String, role: String }",
    )
  let assert [
    ast.CustomType(
      publicity: ast.Private,
      opaque_: True,
      name: "Email",
      variants: [ast.Variant(name: "Email", fields: [_], ..)],
      ..,
    ),
  ] = items("opaque type Email { address: String }")
  let assert [
    ast.CustomType(
      params: ["item"],
      variants: [
        ast.Variant(
          fields: [
            ast.Field(
              label: Some("items"),
              type_: ast.NamedType(
                name: "List",
                args: [ast.VarType(name: "item", ..)],
                ..,
              ),
              ..,
            ),
          ],
          ..,
        ),
      ],
      ..,
    ),
  ] = items("pub type Page(item) { items: List(item) }")
}

pub fn record_spans_test() {
  let source = "pub type Point { x: Float, y: Float }\n"
  let assert [
    ast.CustomType(
      span: type_span,
      name_span: name_span,
      variants: [ast.Variant(span: variant_span, fields: [x, y], ..)],
      ..,
    ),
  ] = items(source)
  let text = fn(s: span.Span) { string.slice(source, s.start, s.end - s.start) }
  // The type covers the whole declaration; the constructor is the braces
  // with its fields.
  assert type_span.start == 0
  assert type_span.end == 37
  assert text(name_span) == "Point"
  assert text(variant_span) == "{ x: Float, y: Float }"
  assert text(x.span) == "x: Float"
  assert text(y.span) == "y: Float"
}

pub fn long_form_constructor_span_is_unchanged_test() {
  let source = "pub type Point {\n  Point(x: Float)\n}"
  let assert [ast.CustomType(variants: [ast.Variant(span: s, ..)], ..)] =
    items(source)
  assert string.slice(source, s.start, s.end - s.start) == "Point(x: Float)"
}

pub fn types_with_constructors_are_unchanged_test() {
  let assert [ast.CustomType(variants: [_, _], ..)] =
    items("pub type Shape {\n  Circle(r: Float)\n  Square\n}")
  let assert [ast.CustomType(variants: [], ..)] = items("pub type Never {}")
  let assert [ast.ExternalType(name: "Box", params: ["a"], ..)] =
    items("pub type Box(a)")
  let assert [ast.TypeAlias(params: ["a"], ..)] =
    items("pub type Wrapped(a) = List(a)")
}

pub fn the_parenthesised_shorthand_is_an_error_test() {
  // Parentheses after a type's name hold its parameters.
  assert parse_errors("pub type Point(x: Float, y: Float)")
    == ["Unexpected `:`"]
  assert parse_errors("pub type UserId(Int)") == ["Unexpected type `Int`"]
}

pub fn record_errors_test() {
  // Fields are separated by commas.
  assert parse_errors("pub type T {\n  a: Int\n  b: String\n}")
    == ["Unexpected name `b`"]
  assert parse_errors("pub type T { a: Int, String }") == ["Unlabelled field"]
  assert parse_errors("pub type T { a: Int, Other(b: String) }")
    == ["Not a field"]
  assert parse_errors("pub type T { a: Int, List(Int) }") == ["Not a field"]
}

// --- Formatter -------------------------------------------------------------------

pub fn formatter_keeps_records_test() {
  let source =
    "/// A token.\n@derive(decoder)\npub type AuthToken { sub: String, role: String }\n\ntype Point { x: Float, y: Float }\n\npub opaque type Email { address: String }\n\npub type Page(item) { items: List(item), total: Int }\n"
  assert format(source) == source
}

pub fn formatter_keeps_records_one_field_per_line_test() {
  let source = "pub type AuthToken {\n  sub: String,\n  role: String,\n}\n"
  assert format(source) == source
  // A missing trailing comma is added.
  assert format("pub type AuthToken {\n  sub: String,\n  role: String\n}\n")
    == source
}

pub fn formatter_keeps_long_form_test() {
  let source =
    "pub type AuthToken {\n  AuthToken(sub: String, role: String)\n}\n"
  assert format(source) == source
}

pub fn formatter_normalises_record_layout_test() {
  assert format("pub   type Point{x:Float,   y : Float ,}\n")
    == "pub type Point { x: Float, y: Float }\n"
}

pub fn formatter_breaks_long_records_test() {
  let out =
    format(
      "pub type Settings { name: String, timeout_in_milliseconds: Int, retries: Int, verbose: Bool }\n",
    )
  assert out
    == "pub type Settings {\n  name: String,\n  timeout_in_milliseconds: Int,\n  retries: Int,\n  verbose: Bool,\n}\n"
  assert format(out) == out
}

pub fn formatter_keeps_comments_in_records_test() {
  let source =
    "// before\npub type Email {\n  // the address\n  address: String,\n  verified: Bool, // checked\n}\n"
  assert format(source) == source
  assert format(format(source)) == source
}

pub fn formatter_keeps_comment_after_attribute_test() {
  let source = "@derive(decoder)\n// note\npub type T { a: Int }\n"
  assert format(source) == source
}

// --- Code generation -------------------------------------------------------------

const program = "import gleam/int

TYPE

pub def describe(p: Point) -> String {
  Point(x:, y: _) = p
  case p {
    Point(x: 0, ..) -> \"on the axis\"
    Point(x, y) if x > y -> int.to_string(x)
    _ -> \"elsewhere\"
  }
}

pub def moved(p: Point) -> Point {
  Point(p | y: p.y + 1)
}

pub def make() -> List(Point) {
  [Point(1, 2), Point(x: 3, y: 4), Point(y: 5, x: 6)]
}
"

pub fn record_generates_the_long_form_gleam_test() {
  let short =
    string.replace(
      program,
      "TYPE",
      "/// A point.\npub type Point { x: Int, y: Int }",
    )
  let long =
    string.replace(
      program,
      "TYPE",
      "/// A point.\npub type Point {\n  Point(x: Int, y: Int)\n}",
    )
  let out = gleam(short)
  assert out == gleam(long)
  assert string.contains(
    out,
    "/// A point.\npub type Point {\n  Point(x: Int, y: Int)\n}",
  )
  // The pattern can't fail: one constructor, as in the long form.
  assert string.contains(out, "let Point(x: x, y: _) = p")
}

pub fn each_equivalent_generates_the_same_gleam_test() {
  list.each(equivalents, fn(pair) {
    let #(short, long) = pair
    // Without the deriver (not imported here) the attribute would be an error.
    let short = string.replace(short, "@derive(decoder)\n", "")
    let long = string.replace(long, "@derive(decoder)\n", "")
    let short = "import gleam/time/timestamp as time\n" <> short
    let long = "import gleam/time/timestamp as time\n" <> long
    assert gleam(short) == gleam(long)
  })
}

pub fn generic_record_generates_the_long_form_test() {
  let out = gleam("pub type Page(item) { items: List(item), total: Int }")
  assert out
    == gleam("pub type Page(item) {\n  Page(items: List(item), total: Int)\n}")
  assert string.contains(
    out,
    "pub type Page(item) {\n  Page(items: List(item), total: Int)\n}",
  )
}

pub fn record_derives_like_the_long_form_test() {
  let header = "import my_json/decoder\nimport my_json/encoder\n\n"
  let main =
    "\n\npub def parse() {\n  Credentials.decoder()\n}\n\npub def write() {\n  Credentials.encoder\n}\n"
  let short =
    header
    <> "@derive(decoder, encoder)\npub type Credentials { username: String, password: String }"
    <> main
  let long =
    header
    <> "@derive(decoder, encoder)\npub type Credentials {\n  Credentials(username: String, password: String)\n}"
    <> main
  let out = gleam(short)
  assert out == gleam(long)
  assert string.contains(out, "pub fn credentials_decoder() {")
  assert string.contains(out, "pub fn credentials_encoder(")
  // Associated functions resolve through the type.
  assert string.contains(out, "  credentials_decoder()\n")
  assert string.contains(out, "  credentials_encoder\n")
}

pub fn generic_record_derives_like_the_long_form_test() {
  let header = "import my_json/decoder\n\n"
  let short =
    header <> "@derive(decoder)\npub type Page(item) { items: List(item) }"
  let long =
    header
    <> "@derive(decoder)\npub type Page(item) {\n  Page(items: List(item))\n}"
  let out = gleam(short)
  assert out == gleam(long)
  assert string.contains(out, "pub fn page_decoder(item_decoder) {")
}

pub fn record_constructor_is_a_single_constructor_test() {
  let assert Ok(module) = compiler.parse("pub type Point { x: Int, y: Int }")
  let assert Ok(long) =
    compiler.parse("pub type Point {\n  Point(x: Int, y: Int)\n}")
  assert codegen.exported_single_constructors(module)
    == codegen.exported_single_constructors(long)
}
