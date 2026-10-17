import bea/codegen
import bea/compiler
import gleam/list
import gleam/string

fn gleam(source: String) -> String {
  let assert Ok(compiled) = compiler.compile(source, codegen.empty_context())
  compiled.gleam
}

fn errors(source: String) -> List(String) {
  let assert Error(diags) = compiler.compile(source, codegen.empty_context())
  list.map(diags, fn(d) { d.title })
}

pub fn guard_clause_return_test() {
  let out =
    gleam(
      "pub def f(n) {\n  if n > 0 {\n    return \"pos\"\n  }\n  \"other\"\n}",
    )
  assert string.contains(out, "use <- bool.guard(when: n > 0, return: \"pos\")")
  assert string.contains(out, "import gleam/bool")
}

pub fn non_trivial_return_is_lazy_test() {
  let out = gleam("pub def f(n) {\n  if n > 0 {\n    return g(n)\n  }\n  0\n}")
  assert string.contains(
    out,
    "bool.lazy_guard(when: n > 0, return: fn() { g(n) })",
  )
}

pub fn try_uses_result_try_test() {
  let out = gleam("pub def f(s) {\n  x = parse(s)?\n  Ok(x)\n}")
  assert string.contains(out, "use x <- result.try(parse(s))")
}

pub fn try_helper_avoids_shadowed_name_test() {
  let out = gleam("pub def f(s) {\n  result = parse(s)?\n  Ok(result)\n}")
  assert string.contains(out, "import gleam/result.{try as bea_result_try}")
  assert string.contains(out, "use result <- bea_result_try(parse(s))")
}

pub fn auto_imports_test() {
  let out =
    gleam(
      "pub def f(xs: List(Int)) -> Option(Int) {\n  list.first(xs) |> option.from_result\n}",
    )
  assert string.contains(out, "import gleam/list")
  assert string.contains(out, "import gleam/option.{type Option}")
}

pub fn no_auto_import_for_local_variable_test() {
  // `list` is a parameter here, so `list.x` is field access, not a module.
  let out = gleam("pub def f(list) {\n  list.x\n}")
  assert !string.contains(out, "import gleam/list")
}

pub fn no_auto_import_for_local_constructor_test() {
  let out =
    gleam("pub type M {\n  Some(Int)\n  Nothing\n}\npub def f() { Some(1) }")
  assert !string.contains(out, "gleam/option")
}

pub fn strings_in_text_are_not_imports_test() {
  let out = gleam("pub def f() { \"Dict Some None result.x\" }")
  assert !string.contains(out, "import")
}

pub fn multi_clause_to_case_test() {
  let out =
    gleam(
      "def len(xs: List(a), acc: Int) -> Int\ndef len([], acc) { acc }\ndef len([_ | t], acc) { len(t, acc + 1) }",
    )
  assert string.contains(out, "fn len(arg_0: List(a), acc: Int) -> Int {")
  assert string.contains(out, "case arg_0 {")
  assert string.contains(out, "[_, ..t] -> len(t, acc + 1)")
}

pub fn let_vs_let_assert_test() {
  let out =
    gleam(
      "pub type P {\n  P(Int)\n}\npub def f(p, xs) {\n  P(a) = p\n  [b] = xs\n  a + b\n}",
    )
  assert string.contains(out, "let P(a) = p")
  assert string.contains(out, "let assert [b] = xs")
}

pub fn interpolation_is_wrapped_test() {
  let out = gleam("pub def f(a, b) { \"#{a <> b} and #{c == d |> g}\" }")
  assert string.contains(out, "a <> b <> \" and \" <> { c == d |> g }")
  let out = gleam("pub def f(a) { \"#{a}\" }")
  assert string.contains(out, "\"\" <> a")
}

pub fn nil_and_tuples_test() {
  let out = gleam("pub def f() { ((), (1,), (1, 2)) }")
  assert string.contains(out, "#(Nil, #(1), #(1, 2))")
}

pub fn bit_arrays_test() {
  let out =
    gleam("pub def f(x) {\n  <<x:size(8)-big, \"a\":utf8, rest:bits>>\n}")
  assert string.contains(out, "<<x:size(8)-big, \"a\":utf8, rest:bits>>")
}

pub fn external_function_test() {
  let out =
    gleam(
      "@external(erlang, \"lists\", \"reverse\")\npub def rev(xs: List(a)) -> List(a)",
    )
  assert string.contains(
    out,
    "@external(erlang, \"lists\", \"reverse\")\npub fn rev(xs: List(a)) -> List(a)\n",
  )
}

pub fn semantic_errors_test() {
  assert errors("def f() { foo(return 1) }") == ["Unexpected `return`"]
  assert errors(
      "def f(x) {\n  case x {\n    y if g(y)? -> 1\n    _ -> 2\n  }\n}",
    )
    == ["Unsupported `?`"]
  assert errors("def f(a) { a }\ndef f(a, b) { b }")
    == ["Clauses with different arities"]
  assert errors("def f(a) -> Int") == ["Function without a body"]
  assert errors("def f(test) { test }") == ["Reserved word", "Reserved word"]
}

pub fn try_keeps_evaluation_order_test() {
  let out = gleam("pub def f() {\n  x = a() + b()?\n  Ok(x)\n}")
  // `a()` is bound before `b()` is unwrapped.
  let assert Ok(#(before, after)) = string.split_once(out, "result.try(b())")
  assert string.contains(before, "= a()")
  assert string.contains(after, "bea_val_")
}

pub fn clause_consistency_errors_test() {
  assert errors("def f(0) { 0 }\npub def f(_) { 1 }")
    == ["Inconsistent visibility"]
  assert errors("def h(x: Int) -> Int\ndef h(x: String) -> Int { 1 }")
    == ["Conflicting annotations"]
}

pub fn float_negate_test() {
  let out = gleam("pub def f(x: Float) { -.x }")
  assert string.contains(out, "float.negate(x)")
  assert string.contains(out, "import gleam/float")
}
