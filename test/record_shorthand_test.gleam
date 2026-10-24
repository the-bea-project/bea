//// Record shorthand: `pub type AuthToken(sub: String, role: String)` is
//// exactly `pub type AuthToken { AuthToken(sub: String, role: String) }`.
//// The parser desugars it into the same syntax tree, so everything after
//// parsing (deriving, associated functions, lowering, code generation) is
//// shared; only the formatter looks at which form was written.

import bea/ast
import bea/codegen
import bea/compiler
import bea/formatter
import bea/parser
import gleam/list
import gleam/option.{None, Some}
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

/// Pairs of a shorthand declaration and the long form it stands for.
const equivalents = [
  #(
    "pub type AuthToken(sub: String, role: String)",
    "pub type AuthToken {\n  AuthToken(sub: String, role: String)\n}",
  ),
  #(
    "type Point(x: Float, y: Float)",
    "type Point {\n  Point(x: Float, y: Float)\n}",
  ),
  #("pub type UserId(Int)", "pub type UserId {\n  UserId(Int)\n}"),
  #(
    "pub opaque type Email(String)",
    "pub opaque type Email {\n  Email(String)\n}",
  ),
  #(
    "pub type Mixed(Int, name: String)",
    "pub type Mixed {\n  Mixed(Int, name: String)\n}",
  ),
  #(
    "pub type Rich(\n  at: time.Timestamp,\n  xs: List(Int),\n  f: fn(Int) -> String,\n  pair: #(Int, String),\n  t: (Int, Bool),\n)",
    "pub type Rich {\n  Rich(at: time.Timestamp, xs: List(Int), f: fn(Int) -> String, pair: #(Int, String), t: (Int, Bool))\n}",
  ),
  #(
    "/// A token.\n@derive(decoder)\n@deprecated(\"use Other\")\npub type T(a: Int)",
    "/// A token.\n@derive(decoder)\n@deprecated(\"use Other\")\npub type T {\n  T(a: Int)\n}",
  ),
]

// --- Parser ----------------------------------------------------------------------

pub fn shorthand_parses_like_the_long_form_test() {
  list.each(equivalents, fn(pair) {
    let #(short, long) = pair
    assert shape(short) == shape(long)
  })
}

pub fn shorthand_keeps_visibility_fields_and_docs_test() {
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
      "/// A token.\n@derive(decoder)\npub type AuthToken(sub: String, role: String)",
    )
  let assert [
    ast.CustomType(
      publicity: ast.Private,
      name: "Point",
      variants: [ast.Variant(name: "Point", fields: [_, _], ..)],
      ..,
    ),
  ] = items("type Point(x: Float, y: Float)")
  let assert [
    ast.CustomType(
      opaque_: True,
      variants: [ast.Variant(fields: [ast.Field(label: None, ..)], ..)],
      ..,
    ),
  ] = items("pub opaque type Email(String)")
}

pub fn shorthand_spans_test() {
  let source = "pub type Point(x: Float, y: Float)\n"
  let assert [
    ast.CustomType(
      span: type_span,
      name_span: name_span,
      variants: [ast.Variant(span: variant_span, fields: [x, y], ..)],
      ..,
    ),
  ] = items(source)
  // The type covers the whole declaration, the constructor starts at the
  // name (which is the constructor's name too) and ends with the fields.
  assert type_span.start == 0
  assert type_span.end == 34
  assert string.slice(source, name_span.start, name_span.end - name_span.start)
    == "Point"
  assert variant_span.start == name_span.start
  assert variant_span.end == type_span.end
  assert string.slice(source, x.span.start, x.span.end - x.span.start)
    == "x: Float"
  assert string.slice(source, y.span.start, y.span.end - y.span.start)
    == "y: Float"
}

pub fn long_form_constructor_span_is_unchanged_test() {
  let assert [
    ast.CustomType(
      name_span:,
      variants: [ast.Variant(span: variant_span, ..)],
      ..,
    ),
  ] = items("pub type Point {\n  Point(x: Float)\n}")
  assert variant_span.start > name_span.end
}

pub fn type_parameters_are_not_shorthand_test() {
  // Bare lowercase names keep meaning type parameters.
  let assert [ast.ExternalType(name: "Box", params: ["a"], ..)] =
    items("pub type Box(a)")
  let assert [ast.ExternalType(name: "Pair", params: ["a", "b"], ..)] =
    items("pub type Pair(a, b,)")
  let assert [ast.ExternalType(name: "Unit", params: [], ..)] =
    items("pub type Unit()")
  let assert [ast.CustomType(params: ["a"], variants: [_], ..)] =
    items("pub type Box(a) {\n  Box(value: a)\n}")
  let assert [ast.TypeAlias(params: ["a"], ..)] =
    items("pub type Wrapped(a) = List(a)")
}

pub fn shorthand_rejects_type_parameters_test() {
  assert parse_errors("pub type Box(value: a)")
    == ["Type parameter in record shorthand"]
  assert parse_errors("pub type Pair(a, Int)")
    == ["Type parameter in record shorthand"]
  assert parse_errors("pub type Nested(items: List(item))")
    == ["Type parameter in record shorthand"]
}

pub fn shorthand_has_no_body_test() {
  assert parse_errors("pub type Point(x: Float) {\n  Point(x: Float)\n}")
    == ["Unexpected body"]
  assert parse_errors("pub type Point(x: Float) = Other") == ["Unexpected body"]
}

pub fn shorthand_needs_the_paren_on_the_same_line_test() {
  // Like every type: `(` on the next line isn't the type's.
  assert parse_errors("pub type Point\n(x: Float)") != []
}

// --- Formatter -------------------------------------------------------------------

pub fn formatter_keeps_shorthand_test() {
  let source =
    "/// A token.\n@derive(decoder)\npub type AuthToken(sub: String, role: String)\n\ntype Point(x: Float, y: Float)\n\npub type UserId(Int)\n\npub opaque type Email(String)\n"
  let assert Ok(out) = formatter.format(source)
  assert out == source
}

pub fn formatter_keeps_long_form_test() {
  let source =
    "pub type AuthToken {\n  AuthToken(sub: String, role: String)\n}\n"
  let assert Ok(out) = formatter.format(source)
  assert out == source
}

pub fn formatter_normalises_shorthand_layout_test() {
  let assert Ok(out) =
    formatter.format("pub   type Point(x:Float,\n   y : Float ,)\n")
  assert out == "pub type Point(x: Float, y: Float)\n"
}

pub fn formatter_breaks_long_shorthand_test() {
  let source =
    "pub type Settings(name: String, timeout_in_milliseconds: Int, retries: Int, verbose: Bool)\n"
  let assert Ok(out) = formatter.format(source)
  assert out
    == "pub type Settings(\n  name: String,\n  timeout_in_milliseconds: Int,\n  retries: Int,\n  verbose: Bool,\n)\n"
  let assert Ok(again) = formatter.format(out)
  assert again == out
}

pub fn formatter_keeps_comments_in_shorthand_test() {
  let source =
    "// before\npub type Email(\n  // the address\n  address: String,\n  verified: Bool, // checked\n)\n"
  let assert Ok(out) = formatter.format(source)
  assert out == source
  let assert Ok(again) = formatter.format(out)
  assert again == out
}

pub fn formatter_keeps_comment_after_attribute_test() {
  let source = "@derive(decoder)\n// note\npub type T(a: Int)\n"
  let assert Ok(out) = formatter.format(source)
  assert out == source
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

pub fn shorthand_generates_the_long_form_gleam_test() {
  let short =
    string.replace(
      program,
      "TYPE",
      "/// A point.\npub type Point(x: Int, y: Int)",
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

pub fn shorthand_derives_like_the_long_form_test() {
  let header = "import my_json/decoder\nimport my_json/encoder\n\n"
  let main =
    "\n\npub def parse() {\n  Credentials.decoder()\n}\n\npub def write() {\n  Credentials.encoder\n}\n"
  let short =
    header
    <> "@derive(decoder, encoder)\npub type Credentials(username: String, password: String)"
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

pub fn shorthand_constructor_is_a_single_constructor_test() {
  let assert Ok(module) = compiler.parse("pub type Point(x: Int, y: Int)")
  let assert Ok(long) =
    compiler.parse("pub type Point {\n  Point(x: Int, y: Int)\n}")
  assert codegen.exported_single_constructors(module)
    == codegen.exported_single_constructors(long)
}
