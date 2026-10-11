// src/bea/codegen.gleam

import bea/ast
import gleam/int
import gleam/list
import gleam/set.{type Set}
import gleam/string

pub fn generate(program: ast.Program) -> String {
  let ast.Program(statements) = program

  // 1. Walk the AST to collect required imports
  let imports_set = collect_imports(statements, set.new())
  let imports_str =
    imports_set
    |> set.to_list()
    |> list.map(fn(mod) { "import " <> mod })
    |> string.join("\n")

  // 2. Generate the main body code
  let body_str =
    statements
    |> list.map(generate_statement)
    |> string.join("\n\n")

  // 3. Stitch them together
  case imports_str {
    "" -> body_str
    _ -> imports_str <> "\n\n" <> body_str
  }
}

// Recursively walks a list of statements
fn collect_imports(
  statements: List(ast.Statement),
  imports: Set(String),
) -> Set(String) {
  case statements {
    [] -> imports
    [stmt, ..rest] -> {
      let new_imports = analyze_statement(stmt, imports)
      collect_imports(rest, new_imports)
    }
  }
}

// Checks specific AST nodes for features that require Gleam standard libraries
fn analyze_statement(stmt: ast.Statement, imports: Set(String)) -> Set(String) {
  case stmt {
    ast.DefStmt(_, _, body) -> collect_imports(body, imports)

    ast.IfStmt(_, body, else_body) -> {
      let base_imports =
        imports
        |> collect_imports(body, _)
        |> collect_imports(else_body, _)

      case body {
        // Trigger bool.guard anytime the body is a single return
        [ast.ReturnStmt(_)] -> set.insert(base_imports, "gleam/bool")
        _ -> base_imports
      }
    }

    _ -> imports
  }
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

    // 5. Map `if/else` to a Gleam use construct
    ast.IfStmt(condition, body, else_body) -> {
      let cond_str = generate_expression(condition)

      case body {
        // 1. If the body is JUST an early return, use bool.guard
        [ast.ReturnStmt(ret_expr)] -> {
          let ret_str = generate_expression(ret_expr)
          let guard_str =
            "use <- bool.guard(when: "
            <> cond_str
            <> ", return: "
            <> ret_str
            <> ")"

          case else_body {
            [] -> guard_str
            // 2. If there is an else block, flatten it to run AFTER the guard!
            _ -> {
              let else_str =
                else_body
                |> list.map(generate_statement)
                |> string.join("\n  ")
              guard_str <> "\n  " <> else_str
            }
          }
        }

        // 3. Standard If/Else logic for multi-line bodies
        _ -> {
          let body_str =
            body |> list.map(generate_statement) |> string.join("\n      ")

          case else_body {
            [] ->
              "case "
              <> cond_str
              <> " {\n    True -> {\n      "
              <> body_str
              <> "\n    }\n    False -> Nil\n  }"
            _ -> {
              let else_str =
                else_body
                |> list.map(generate_statement)
                |> string.join("\n      ")
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
  }
}

fn generate_expression(expr: ast.Expr) -> String {
  case expr {
    ast.IntExpr(val) -> int.to_string(val)
    ast.StringExpr(val) -> "\"" <> val <> "\""
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

    // Generate list syntax
    ast.ListExpr(elements) -> {
      let elements_str =
        elements |> list.map(generate_expression) |> string.join(", ")
      "[" <> elements_str <> "]"
    }
  }
}
