import bea/ast
import bea/parser
import gleam/list
import gleam/option.{None, Some}

fn body(source: String) -> List(ast.Statement) {
  let result = parser.parse_module("def f() {\n" <> source <> "\n}")
  let assert [] = result.errors
  let assert [ast.Function(clauses: [clause], ..)] = result.module.items
  let assert Some(stmts) = clause.body
  stmts
}

fn expr(source: String) -> ast.Expr {
  let assert [ast.Expression(e)] = body(source)
  e
}

pub fn precedence_test() {
  let assert ast.BinaryOp(
    _,
    ast.Add,
    ast.Int(_, "1"),
    ast.BinaryOp(_, ast.Mul, _, _),
  ) = expr("1 + 2 * 3")
  let assert ast.BinaryOp(_, ast.Or, ast.BinaryOp(_, ast.And, _, _), _) =
    expr("a and b or c")
  let assert ast.BinaryOp(_, ast.Eq, ast.BinaryOp(_, ast.Pipe, _, _), _) =
    expr("x |> f == y")
  let assert ast.BinaryOp(
    _,
    ast.Sub,
    ast.BinaryOp(_, ast.Sub, _, _),
    ast.Int(_, "3"),
  ) = expr("10 - 4 - 3")
}

pub fn try_after_pipe_applies_to_pipeline_test() {
  let assert ast.Try(
    _,
    ast.BinaryOp(_, ast.Pipe, ast.Var(_, "s"), ast.Call(..)),
  ) = expr("s |> parse()?")
}

pub fn list_cons_keeps_all_heads_test() {
  let assert ast.List(
    _,
    [ast.Int(_, "1"), ast.Int(_, "2")],
    Some(ast.Var(_, "rest")),
  ) = expr("[1, 2 | rest]")
}

pub fn call_needs_same_line_test() {
  // A `(` on the next line starts a new statement (a tuple pattern here).
  let assert [ast.Assign(..), ast.Assign(_, ast.PTuple(..), None, _)] =
    body("x = foo\n(a, b) = pair")
}

pub fn minus_on_new_line_starts_new_statement_test() {
  let assert [
    ast.Assign(_, _, _, ast.Var(_, "b")),
    ast.Expression(ast.Int(_, "-1")),
  ] = body("a = b\n-1")
}

pub fn record_update_test() {
  let assert ast.RecordUpdate(
    _,
    ast.Constructor(_, None, "Team"),
    ast.Var(_, "t"),
    [ast.Arg(_, Some("coach"), None)],
  ) = expr("Team(t | coach:)")
}

pub fn partial_record_pattern_test() {
  let result = parser.parse_module("def f(Player(name: n | _)) { n }")
  let assert [] = result.errors
  let assert [ast.Function(clauses: [clause], ..)] = result.module.items
  let assert [
    ast.Param(pattern: ast.PConstructor(_, None, "Player", [_], True), ..),
  ] = clause.params
}

pub fn map_update_test() {
  let assert ast.Map(_, Some(ast.Var(_, "m")), [_, _]) =
    expr("%{m | \"a\": 1, \"b\": 2}")
}

pub fn clauses_are_collapsed_test() {
  let result =
    parser.parse_module(
      "def f([]) { 0 }\ndef f([_ | t]) { 1 + f(t) }\ndef g() { 1 }",
    )
  let assert [] = result.errors
  let assert [
    ast.Function(name: "f", clauses: [_, _], ..),
    ast.Function(name: "g", ..),
  ] = result.module.items
}

pub fn types_test() {
  let result =
    parser.parse_module(
      "pub opaque type Box(a) { Box(value: a) }\npub type Usd\ntype Pair = (Int, String)\n@external(erlang, \"m\", \"f\")\npub def ext(x: Int) -> option.Option(Int)",
    )
  let assert [] = result.errors
  let assert [
    ast.CustomType(opaque_: True, params: ["a"], ..),
    ast.ExternalType(name: "Usd", ..),
    ast.TypeAlias(aliased: ast.TupleType(_, [_, _]), ..),
    ast.Function(clauses: [clause], ..),
  ] = result.module.items
  let assert [ast.Attribute(name: "external", ..)] = clause.attributes
  let assert Some(ast.NamedType(_, Some("option"), "Option", [_])) =
    clause.return_type
}

pub fn errors_recover_per_definition_test() {
  let result =
    parser.parse_module(
      "def a() { 1 + }\ndef b() { ok }\ndef c( { }\ndef d() { 2 }",
    )
  assert list.length(result.errors) == 2
  let names =
    list.filter_map(result.module.items, fn(it) {
      case it {
        ast.Function(name:, ..) -> Ok(name)
        _ -> Error(Nil)
      }
    })
  assert names == ["b", "d"]
}

pub fn doc_comments_attach_to_definitions_test() {
  let result =
    parser.parse_module("/// Adds\n/// numbers\npub def add(a, b) { a + b }")
  let assert [ast.Function(clauses: [clause], ..)] = result.module.items
  assert clause.doc == [" Adds", " numbers"]
}

pub fn keywords_as_gleam_names_test() {
  let assert ast.Call(_, ast.FieldAccess(_, ast.Var(_, "bool"), "and", _), _) =
    expr("bool.and(a, b)")
  let assert ast.Call(
    _,
    _,
    [ast.Arg(_, Some("when"), _), ast.Arg(_, Some("return"), _)],
  ) = expr("bool.guard(when: c, return: 0)")
}

pub fn try_lifts_through_field_access_test() {
  let assert ast.FieldAccess(
    _,
    ast.Try(_, ast.BinaryOp(_, ast.Pipe, _, _)),
    "name",
    _,
  ) = expr("s |> mk()?.name")
}

pub fn minus_inside_parens_continues_test() {
  let assert ast.Tuple(_, [_, ast.BinaryOp(_, ast.Sub, _, _)]) =
    expr("(a, b\n - 1)")
}

pub fn bare_return_test() {
  let assert [ast.Return(_, ast.Constructor(_, None, "Nil"))] = body("return")
}

pub fn float_negation_test() {
  let assert ast.NegateFloat(_, ast.Var(_, "x")) = expr("-.x")
  let assert ast.Float(_, "-1.5") = expr("-.1.5")
}
