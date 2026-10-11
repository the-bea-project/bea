// src/bea/codegen.gleam

import bea/ast
import gleam/int
import gleam/list
import gleam/string

pub fn generate(program: ast.Program) -> String {
  let ast.Program(statements) = program

  statements
  |> list.map(generate_statement)
  |> string.join("\n\n")
}

fn generate_statement(stmt: ast.Statement) -> String {
  case stmt {
    // 1. Map `def` to `pub fn`
    ast.DefStmt(name, params, body) -> {
      let params_str = string.join(params, ", ")
      let body_str =
        body
        |> list.map(generate_statement)
        |> string.join("\n  ")
      "pub fn " <> name <> "(" <> params_str <> ") {\n  " <> body_str <> "\n}"
    }

    // 2. Gleam doesn't use the `return` keyword, so we just output the expression
    ast.ReturnStmt(expr) -> generate_expression(expr)

    // 3. Map assignments to `let`
    ast.AssignStmt(name, expr) ->
      "let " <> name <> " = " <> generate_expression(expr)

    // 4. Standalone expressions
    ast.ExprStmt(expr) -> generate_expression(expr)

    // 5. Map `if/else` to Gleam's `case` statement
    ast.IfStmt(condition, body, else_body) -> {
      let cond_str = generate_expression(condition)
      let body_str =
        body |> list.map(generate_statement) |> string.join("\n      ")

      case else_body {
        // No else block
        [] ->
          "case "
          <> cond_str
          <> " {\n    True -> {\n      "
          <> body_str
          <> "\n    }\n    False -> Nil\n  }"
        // Has an else block
        _ -> {
          let else_str =
            else_body |> list.map(generate_statement) |> string.join("\n      ")
          "case "
          <> cond_str
          <> " {\n    True -> {\n      "
          <> body_str
          <> "\n    }\n    False -> {\n      "
          <> else_str
          <> "\n    }\n  }"
        }
      }
    }
  }
}

fn generate_expression(expr: ast.Expr) -> String {
  case expr {
    ast.IntExpr(val) -> int.to_string(val)
    ast.StringExpr(val) -> "\"" <> val <> "\""
    // Wrap strings back in quotes
    ast.IdentExpr(name) -> name

    ast.BinaryExpr(left, op, right) ->
      generate_expression(left)
      <> " "
      <> op
      <> " "
      <> generate_expression(right)

    ast.CallExpr(name, args) -> {
      let args_str = args |> list.map(generate_expression) |> string.join(", ")
      name <> "(" <> args_str <> ")"
    }
  }
}
