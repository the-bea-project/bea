//// Regression tests for compiler bugs found while migrating the compiler to
//// Bea (see docs/self-hosting.md).

import bea/ast
import bea/codegen
import bea/compiler
import bea/formatter
import bea/parser
import gleam/option.{None, Some}
import gleam/string

fn gleam(source: String) -> String {
  let assert Ok(compiled) = compiler.compile(source, codegen.empty_context())
  compiled.gleam
}

/// Gleam's formatter writes a trailing comma after `..` when a constructor
/// pattern spans several lines; Bea, which reads Gleam's `..` spread,
/// rejected it with "Unexpected `,`".
pub fn spread_with_trailing_comma_test() {
  let source =
    "pub type Point {\n  Point(x: Int, y: Int)\n}\n\npub def x(p) {\n  case p {\n    Point(\n      x:,\n      ..,\n    ) -> x\n  }\n}\n"
  let result = parser.parse_module(source)
  assert result.errors == []
  let assert [_, ast.Function(clauses: [clause], ..)] = result.module.items
  let assert Some([ast.Expression(ast.Case(clauses: [arm], ..))]) = clause.body
  let assert [
    [
      ast.PConstructor(
        name: "Point",
        args: [ast.PatternArg(label: Some("x"), value: None, ..)],
        spread: True,
        ..,
      ),
    ],
  ] = arm.alternatives
  assert string.contains(gleam(source), "Point(x: x, ..) -> x")
  // The same as without the comma, and formatted the Bea way.
  let assert Ok(formatted) = formatter.format(source)
  assert string.contains(formatted, "Point(x: | _) -> x")
  assert gleam(source)
    == gleam(string.replace(source, "      ..,\n", "      ..\n"))
}

pub fn spread_with_trailing_comma_in_parameters_test() {
  let source =
    "pub type Point {\n  Point(x: Int, y: Int)\n}\n\npub def x(Point(x:, ..,)) {\n  x\n}\n"
  assert parser.parse_module(source).errors == []
  assert string.contains(
    gleam(source),
    "pub fn x(arg_0) {\n  case arg_0 {\n    Point(x: x, ..) -> x\n  }\n}",
  )
}
