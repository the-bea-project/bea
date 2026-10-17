import bea/codegen
import bea/compiler
import bea/diagnostic
import bea/lsp/json
import bea/lsp/position
import bea/project
import bea/sourcemap
import bea/span.{Span}
import gleam/option.{Some}
import gleam/string

pub fn json_round_trip_test() {
  let text =
    "{\"a\":[1,2.5,-3,true,false,null],\"b\":{\"c\":\"q\\\"\\n\\u00e9\\ud83d\\ude00\"},\"e\":1.0e5}"
  let assert Ok(value) = json.parse(text)
  assert json.string_at(value, ["b", "c"]) == Some("q\"\né😀")
  let assert Ok(again) = json.parse(json.to_string(value))
  assert again == value
}

pub fn json_set_keeps_order_test() {
  let assert Ok(value) = json.parse("{\"x\":1,\"y\":2}")
  assert json.to_string(json.set(value, "x", json.Int(5)))
    == "{\"x\":5,\"y\":2}"
}

pub fn uri_test() {
  assert position.uri_to_path("file:///tmp/My%20Project/a.bea")
    == Some("/tmp/My Project/a.bea")
  assert position.path_to_uri("/tmp/My Project/a.bea")
    == "file:///tmp/My%20Project/a.bea"
}

pub fn sourcemap_identifiers_round_trip_test() {
  let source =
    "pub def area(width: Int, height: Int) -> Int {\n  width * height\n}\n"
  let assert Ok(compiled) = compiler.compile(source, codegen.empty_context())
  let map = sourcemap.new(compiled.mappings, source, compiled.gleam)
  // `height` in the body
  let assert [_, _, after] = string.split(source, "height")
  let bea_offset = string.byte_size(source) - string.byte_size(after) - 6
  assert span.text(source, Span(bea_offset, bea_offset + 6)) == "height"
  let assert Some(gleam_offset) = sourcemap.to_gleam_offset(map, bea_offset)
  assert span.text(compiled.gleam, Span(gleam_offset, gleam_offset + 6))
    == "height"
  assert sourcemap.to_bea_offset(map, gleam_offset) == Some(bea_offset)
}

pub fn utf16_positions_test() {
  let index = span.line_index("a\n😀x = 1")
  // `x` is after a 4 byte emoji that counts as 2 UTF-16 units.
  assert span.utf16_position(index, 6) == span.Position(1, 2)
  assert span.utf16_offset(index, span.Position(1, 2)) == 6
}

pub fn package_name_test() {
  assert project.package_name(
      "name = \"app\"\nversion = \"1\"\n[deps]\nname = \"x\"",
    )
    == Ok("app")
}

pub fn diagnostics_render_test() {
  let assert Error([d]) =
    compiler.compile("def f() { 1 + }", codegen.empty_context())
  let rendered = d |> render
  assert string.contains(rendered, "1 │ def f() { 1 + }")
  assert string.contains(
    rendered,
    "              ^ I was expecting an expression",
  )
}

fn render(d: diagnostic.Diagnostic) -> String {
  diagnostic.render(d, "x.bea", "def f() { 1 + }", False)
}
