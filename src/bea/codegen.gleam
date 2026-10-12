// src/bea/codegen.gleam
import bea/ast
import gleam/float
import gleam/int
import gleam/list
import gleam/result
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
    |> list.filter(fn(s) {
      case s {
        ast.ImportStmt(_) -> False
        _ -> True
      }
    })
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
    // ADDED an extra '_' here so there are 4 arguments total
    ast.DefStmt(_, _, _, clauses) ->
      list.fold(clauses, imports, fn(acc, clause) {
        collect_imports(clause.body, acc)
      })

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

    ast.ImportStmt(path) -> set.insert(imports, path)

    _ -> imports
  }
}

fn generate_statement(stmt: ast.Statement) -> String {
  case stmt {
    // ADDED return_type here
    ast.DefStmt(is_pub, name, return_type, clauses) -> {
      let pub_prefix = case is_pub {
        True -> "pub "
        False -> ""
      }

      // Build the return string
      let ret_str = case return_type {
        "" -> ""
        t -> " -> " <> t
      }

      case clauses {
        [ast.Clause(params, body)] -> {
          case is_simple_params(params) {
            True -> {
              let params_str =
                params |> list.map(generate_pattern) |> string.join(", ")
              let body_str =
                body |> list.map(generate_statement) |> string.join("\n  ")
              pub_prefix
              <> "fn "
              <> name
              <> "("
              <> params_str
              <> ")"
              <> ret_str
              // INJECTED HERE
              <> " {\n  "
              <> body_str
              <> "\n}"
            }
            // PASSED return_type
            False -> generate_multi_clause(is_pub, name, return_type, clauses)
          }
        }
        // PASSED return_type
        _ -> generate_multi_clause(is_pub, name, return_type, clauses)
      }
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

    ast.ImportStmt(_) -> ""
  }
}

fn generate_multi_clause(
  is_pub: Bool,
  name: String,
  return_type: String,
  // ADDED HERE
  clauses: List(ast.Clause),
) -> String {
  let pub_prefix = case is_pub {
    True -> "pub "
    False -> ""
  }

  // Build the return string
  let ret_str = case return_type {
    "" -> ""
    t -> " -> " <> t
  }

  let first_clause = list.first(clauses) |> result.unwrap(ast.Clause([], []))
  let arity = list.length(first_clause.params)

  let synthetic_params = make_synthetic_params(0, arity, [])
  let params_def = string.join(synthetic_params, ", ")

  let match_target = case arity {
    1 -> string.join(synthetic_params, "")
    _ -> "#(" <> string.join(synthetic_params, ", ") <> ")"
  }

  let cases_str =
    clauses
    |> list.map(fn(c) { generate_clause_arm(c, arity) })
    |> string.join("\n    ")

  pub_prefix
  <> "fn "
  <> name
  <> "("
  <> params_def
  <> ")"
  <> ret_str
  // INJECTED HERE
  <> " {\n  case "
  <> match_target
  <> " {\n    "
  <> cases_str
  <> "\n  }\n}"
}

// Helpers for multi-clause codegen
fn is_simple_params(params: List(ast.Expr)) -> Bool {
  list.all(params, fn(p) {
    case p {
      ast.IdentExpr(_) -> True
      ast.TypedExpr(ast.IdentExpr(_), _) -> True
      _ -> False
    }
  })
}

fn generate_clause_arm(clause: ast.Clause, arity: Int) -> String {
  let ast.Clause(params, body) = clause

  let pattern_str = case arity {
    1 ->
      case list.first(params) {
        Ok(p) -> generate_pattern(p)
        Error(_) -> ""
      }
    _ ->
      "#("
      <> { params |> list.map(generate_pattern) |> string.join(", ") }
      <> ")"
  }

  let body_str = body |> list.map(generate_statement) |> string.join("\n      ")

  pattern_str <> " -> {\n      " <> body_str <> "\n    }"
}

fn generate_pattern(expr: ast.Expr) -> String {
  case expr {
    ast.IntExpr(val) -> int.to_string(val)
    ast.StringExpr(val) -> "\"" <> val <> "\""
    ast.IdentExpr(name) -> name
    ast.TypedExpr(inner, type_name) ->
      generate_pattern(inner) <> ": " <> type_name
    _ -> panic as "Unsupported pattern expression"
  }
}

fn generate_expression(expr: ast.Expr) -> String {
  case expr {
    ast.IntExpr(val) -> int.to_string(val)
    ast.FloatExpr(val) -> float.to_string(val)
    ast.StringExpr(val) -> "\"" <> val <> "\""
    ast.IdentExpr(name) -> name

    ast.UnaryExpr("not", inner) -> "!" <> generate_expression(inner)
    ast.UnaryExpr(op, _) -> panic as { "Unsupported unary operator: " <> op }

    ast.TypedExpr(inner, type_name) ->
      generate_expression(inner) <> ": " <> type_name

    ast.BinaryExpr(left, op, right) -> {
      let gleam_op = case op {
        "and" -> "&&"
        "or" -> "||"
        other -> other
      }
      generate_expression(left)
      <> " "
      <> gleam_op
      <> " "
      <> generate_expression(right)
    }

    ast.CallExpr(name, args) -> {
      let args_str = args |> list.map(generate_expression) |> string.join(", ")
      name <> "(" <> args_str <> ")"
    }

    ast.EchoExpr(inner) -> "{ echo " <> generate_expression(inner) <> " }"

    // Generate list syntax
    ast.ListExpr(elements) -> {
      let elements_str =
        elements |> list.map(generate_expression) |> string.join(", ")
      "[" <> elements_str <> "]"
    }
  }
}

// Recursive helper to build ["arg_0", "arg_1", ...] up to arity
fn make_synthetic_params(
  current: Int,
  arity: Int,
  acc: List(String),
) -> List(String) {
  case current >= arity {
    True -> list.reverse(acc)
    False ->
      make_synthetic_params(current + 1, arity, [
        "arg_" <> int.to_string(current),
        ..acc
      ])
  }
}
