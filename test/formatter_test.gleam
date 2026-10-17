import bea/formatter
import gleam/list
import gleam/string
import simplifile

fn files() -> List(String) {
  let assert Ok(beacode) = simplifile.read_directory("beacode")
  let assert Ok(fixtures) = simplifile.read_directory("test/fixtures")
  list.flatten([
    list.map(beacode, fn(f) { "beacode/" <> f }),
    list.map(fixtures, fn(f) { "test/fixtures/" <> f }),
  ])
  |> list.filter(fn(f) { string.ends_with(f, ".bea") })
}

pub fn formats_all_examples_idempotently_test() {
  list.each(files(), fn(path) {
    let assert Ok(source) = simplifile.read(path)
    let assert Ok(once) = formatter.format(source)
    let assert Ok(twice) = formatter.format(once)
    assert once == twice
  })
}

pub fn keeps_comments_test() {
  let source =
    "// top\nimport gleam/io // why\n\npub def main() {\n  // inside\n  x = [\n    1, // one\n    2,\n  ]\n  io.println(x) // trailing\n  // end\n}\n"
  let assert Ok(out) = formatter.format(source)
  assert out == source
}

pub fn canonical_style_test() {
  let source = "def f(a,b){\nx=a+b\nif x>1{return #(1,2)}\n[a,..rest]=xs\nx}"
  let assert Ok(out) = formatter.format(source)
  assert out
    == "def f(a, b) {\n  x = a + b\n  if x > 1 {\n    return (1, 2)\n  }\n  [a | rest] = xs\n  x\n}\n"
}

pub fn refuses_broken_code_test() {
  let assert Error(_) = formatter.format("def f( {")
}
