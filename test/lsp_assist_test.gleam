import bea/codegen
import bea/compiler
import bea/lsp/assist
import bea/lsp/index
import bea/lsp/json
import bea/lsp/repair
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

fn offset_after(text: String, needle: String) -> Int {
  let assert Ok(#(before, _)) = string.split_once(text, needle)
  string.byte_size(before) + string.byte_size(needle)
}

/// The first repaired copy that compiles.
fn repaired(text: String, needle: String, hole: String) -> Result(String, Nil) {
  repair.candidates(text, offset_after(text, needle), hole)
  |> list.find(fn(c) {
    result.is_ok(compiler.compile(c, codegen.empty_context()))
  })
}

pub fn repair_after_dot_in_unfinished_constructor_test() {
  let text =
    "import gleam/time/timestamp

pub type Context {
  Context(boot_time: timestamp.Timestamp, n: Int)
}

pub def build() {
  Context(
    timestamp.
    n: 1
  )
}
"
  let assert Ok(fixed) = repaired(text, "    timestamp.", "hole")
  assert string.contains(fixed, "timestamp.hole")
  // Everything after the argument is kept.
  assert string.contains(fixed, "n: 1")
}

pub fn repair_closes_open_calls_test() {
  let text =
    "pub def main() {
  io.println(int.to_string(
}

pub def other() { 1 }
"
  let assert Ok(fixed) = repaired(text, "int.to_string(", "hole")
  assert string.contains(fixed, "int.to_string(hole")
  assert string.contains(fixed, "pub def other()")
}

pub fn no_completion_in_strings_and_comments_test() {
  let text = "pub def f() {\n  // list.\n  \"a #{x.y} b.\" <> \"c.\n}\n"
  assert repair.in_text(text, offset_after(text, "// list."))
  assert !repair.in_text(text, offset_after(text, "#{x."))
  assert repair.in_text(text, offset_after(text, " b."))
  assert repair.in_text(text, offset_after(text, "\"c."))
  assert !repair.in_text(text, offset_after(text, "pub def f"))
}

pub fn call_at_counts_arguments_test() {
  let text = "x = timestamp.add(now(), [1, 2], "
  let assert Ok(call) = repair.call_at(text, string.byte_size(text))
  assert call.qualifier == Ok("timestamp")
  assert call.name == "add"
  assert call.argument == 2
  assert call.label == Error(Nil)
}

pub fn call_at_pipes_and_labels_test() {
  let text = "x |> ewe.bind(to: "
  let assert Ok(call) = repair.call_at(text, string.byte_size(text))
  assert call.name == "bind"
  assert call.argument == 1
  assert call.label == Ok("to")
  // A tuple is not a call; the call around it is.
  let text = "f(1, (a, "
  let assert Ok(call) = repair.call_at(text, string.byte_size(text))
  assert call.name == "f"
  assert call.argument == 1
  // Bit arrays and comments don't add arguments.
  let text = "f(<<1, 2>>, // a, b\n  "
  let assert Ok(call) = repair.call_at(text, string.byte_size(text))
  assert call.argument == 1
  // Parameters of an anonymous function are not a call.
  let text = "list.map(xs, fn(x"
  let assert Ok(call) = repair.call_at(text, string.byte_size(text))
  assert call.name == "map"
  // Inside an anonymous function's body there is no call to show.
  let text = "list.map(xs, fn(x) { x + "
  assert repair.call_at(text, string.byte_size(text)) == Error(Nil)
}

pub fn index_reads_gleam_headers_test() {
  let source =
    "/// Pads a string.
pub fn pad_start(
  string: String,
  to desired_length: Int,
  with pad_string: String,
) -> String {
  todo
}

fn private() { 1 }

pub const answer: Int = 42

pub type Shape {
  /// A circle.
  Circle(radius: Float)
  Square(Float)
}
"
  let entries = index.from_gleam("my/strings", source)
  let assert [pad, answer, circle, square] = entries
  assert pad.name == "pad_start"
  assert pad.doc == "Pads a string."
  assert index.signature(pad, Some("strings"))
    == "strings.pad_start(string: String, to desired_length: Int, with pad_string: String) -> String"
  assert answer.kind == index.Constant
  assert answer.return_type == "Int"
  assert index.signature(circle, None) == "Circle(radius: Float)"
  assert circle.doc == "A circle."
  assert square.kind == index.Constructor
}

pub fn signature_label_offsets_test() {
  let sig =
    json.object([
      #("label", json.String("pair.swap(#(a, b)) -> #(b, a)")),
      #(
        "parameters",
        json.Array([
          json.object([#("label", json.Array([json.Int(10), json.Int(17)]))]),
        ]),
      ),
    ])
  let entry =
    index.Entry(
      "gleam/pair",
      "swap",
      index.Function,
      [index.Param(None, "pair", "#(a, b)")],
      "#(b, a)",
      "",
    )
  let rebuilt = assist.signature(sig, Some(entry))
  let assert Some(label) = json.string_at(rebuilt, ["label"])
  assert label == "pair.swap(pair: (a, b)) -> (b, a)"
  let assert Some(json.Array([param])) = json.get(rebuilt, "parameters")
  assert json.get(param, "label")
    == Some(json.Array([json.Int(10), json.Int(22)]))
}

pub fn external_at_test() {
  let text =
    "@external(erlang, \"my_ffi\", \"now\")
@external(javascript, \"./my_ffi.mjs\", \"now\")
pub def now() -> Int
"
  let assert Some(e) = assist.external_at(text, 3)
  assert e == assist.External("erlang", "my_ffi", "now")
  let assert Some(e) =
    assist.external_at(text, offset_after(text, "javascript"))
  assert e.target == "javascript"
  // On the declaration's name, not on the rest of the line.
  let assert Some(e) = assist.external_at(text, offset_after(text, "pub def n"))
  assert e.module == "my_ffi"
  assert assist.external_at(text, offset_after(text, "-> I")) == None
}
