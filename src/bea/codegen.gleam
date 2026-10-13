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
    // extra '_' here so there are 4 arguments total
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

    // Auto-import gleam/result when the ? operator is used
    ast.AssignStmt(_, ast.TryExpr(_)) -> set.insert(imports, "gleam/result")
    ast.ExprStmt(ast.TryExpr(_)) -> set.insert(imports, "gleam/result")

    _ -> imports
  }
}

fn generate_statement(stmt: ast.Statement) -> String {
  case stmt {
    // Module-level Constants
    ast.ConstStmt(is_pub, name, value) -> {
      let pub_prefix = case is_pub {
        True -> "pub "
        False -> ""
      }
      pub_prefix <> "const " <> name <> " = " <> generate_expression(value)
    }

    // Custom Types (Structs and Enums)
    ast.CustomTypeStmt(is_pub, name, variants) -> {
      let pub_prefix = case is_pub {
        True -> "pub "
        False -> ""
      }

      let variants_str =
        variants
        |> list.map(fn(v) {
          let ast.TypeVariant(v_name, fields) = v
          case fields {
            [] -> v_name
            _ -> {
              let fields_str =
                fields
                |> list.map(fn(f) {
                  let #(f_name, f_type) = f
                  case f_name {
                    "" -> f_type
                    // Unlabeled: just output the type (e.g., "Int")
                    _ -> f_name <> ": " <> f_type
                    // Labeled: output "name: String"
                  }
                })
                |> string.join(", ")
              v_name <> "(" <> fields_str <> ")"
            }
          }
        })
        |> string.join("\n  ")

      pub_prefix <> "type " <> name <> " {\n  " <> variants_str <> "\n}"
    }

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
        // Only simple single-clauses WITHOUT guards stay as standard functions
        [ast.Clause(params, [], body)] -> {
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
              <> " {\n  "
              <> body_str
              <> "\n}"
            }
            False -> generate_multi_clause(is_pub, name, return_type, clauses)
          }
        }
        _ -> generate_multi_clause(is_pub, name, return_type, clauses)
      }
    }

    // 2. Gleam doesn't use the `return` keyword, so we just output the expression
    ast.ReturnStmt(expr) -> generate_expression(expr)

    // 3a. Error Propagation Assignment (The ? Operator)
    ast.AssignStmt(pattern_expr, ast.TryExpr(value_expr)) -> {
      let pat_str = generate_pattern(pattern_expr)
      let val_str = generate_expression(value_expr)
      "use " <> pat_str <> " <- result.try(" <> val_str <> ")"
    }

    // 3b. Standard Assignment
    ast.AssignStmt(pattern_expr, value_expr) -> {
      let pat_str = generate_pattern(pattern_expr)
      let val_str = generate_expression(value_expr)
      case pattern_expr {
        ast.IdentExpr(_) -> "let " <> pat_str <> " = " <> val_str
        _ -> "let assert " <> pat_str <> " = " <> val_str
      }
    }

    // 4a. Error Propagation Standalone Expression
    ast.ExprStmt(ast.TryExpr(value_expr)) -> {
      "use _ <- result.try(" <> generate_expression(value_expr) <> ")"
    }

    // 4b. Standard Standalone Expression
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
  clauses: List(ast.Clause),
) -> String {
  let pub_prefix = case is_pub {
    True -> "pub "
    False -> ""
  }
  let ret_str = case return_type {
    "" -> ""
    t -> " -> " <> t
  }

  let first_clause =
    list.first(clauses) |> result.unwrap(ast.Clause([], [], []))
  let arity = list.length(first_clause.params)

  let args = make_synthetic_params(0, arity, [])

  // 1. Attach types from the Function Head to our generated arguments
  let typed_args =
    list.zip(args, first_clause.params)
    |> list.map(fn(pair) {
      let #(arg, p) = pair
      case p {
        ast.TypedExpr(_, type_name) -> arg <> ": " <> type_name
        _ -> arg
      }
    })

  let params_def = string.join(typed_args, ", ")

  let match_target = string.join(args, ", ")

  // 2. Filter out the Function Head so we don't generate an empty case block
  let valid_clauses = list.filter(clauses, fn(c) { c.body != [] })

  let cases_str =
    valid_clauses
    |> list.map(generate_clause_arm)
    |> string.join("\n    ")

  pub_prefix
  <> "fn "
  <> name
  <> "("
  <> params_def
  <> ")"
  <> ret_str
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

fn generate_clause_arm(clause: ast.Clause) -> String {
  let ast.Clause(params, guard, body) = clause

  let pattern_str = params |> list.map(generate_pattern) |> string.join(", ")

  let guard_str = case guard {
    [] -> ""
    [g] -> " if " <> generate_expression(g)
    _ -> ""
  }

  let body_str = body |> list.map(generate_statement) |> string.join("\n      ")

  pattern_str <> guard_str <> " -> {\n      " <> body_str <> "\n    }"
}

fn generate_pattern(expr: ast.Expr) -> String {
  case expr {
    ast.IntExpr(val) -> int.to_string(val)
    ast.StringExpr(val) -> "\"" <> val <> "\""
    ast.IdentExpr(name) -> name
    ast.TypedExpr(inner, type_name) ->
      generate_pattern(inner) <> ": " <> type_name

    ast.AliasExpr(pattern, name) -> {
      generate_pattern(pattern) <> " as " <> name
    }

    ast.ListExpr(elements) -> {
      let elements_str =
        elements |> list.map(generate_pattern) |> string.join(", ")
      "[" <> elements_str <> "]"
    }

    ast.ListConsExpr(head, tail) -> {
      "[" <> generate_pattern(head) <> ", .." <> generate_pattern(tail) <> "]"
    }

    ast.TupleExpr(elements) -> {
      let elements_str =
        elements |> list.map(generate_pattern) |> string.join(", ")
      "#(" <> elements_str <> ")"
    }

    // Allows destructuring variants with arguments, e.g., Walk(k)
    ast.CallExpr(name, args) -> {
      let args_str =
        args
        |> list.map(fn(arg) {
          let #(label, expr) = arg
          case label {
            "" -> generate_pattern(expr)
            lbl -> lbl <> ": " <> generate_pattern(expr)
          }
        })
        |> string.join(", ")
      name <> "(" <> args_str <> ")"
    }

    _ -> panic as "Unsupported pattern expression"
  }
}

fn generate_expression(expr: ast.Expr) -> String {
  case expr {
    ast.IntExpr(val) -> int.to_string(val)
    ast.FloatExpr(val) -> float.to_string(val)
    ast.StringExpr(val) -> "\"" <> val <> "\""
    ast.IdentExpr(name) -> name

    ast.AliasExpr(pattern, name) -> {
      generate_expression(pattern) <> " as " <> name
    }

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
      let args_str =
        args
        |> list.map(fn(arg) {
          let #(label, expr) = arg
          case label {
            "" -> generate_expression(expr)
            lbl -> lbl <> ": " <> generate_expression(expr)
          }
        })
        |> string.join(", ")
      name <> "(" <> args_str <> ")"
    }

    ast.EchoExpr(inner) -> "{ echo " <> generate_expression(inner) <> " }"

    // Generate list syntax
    ast.ListExpr(elements) -> {
      let elements_str =
        elements |> list.map(generate_expression) |> string.join(", ")
      "[" <> elements_str <> "]"
    }

    ast.ListConsExpr(head, tail) -> {
      "["
      <> generate_expression(head)
      <> ", .."
      <> generate_expression(tail)
      <> "]"
    }

    ast.CondExpr(clauses) -> generate_cond(clauses)

    ast.CaseExpr(subject, clauses) -> {
      let sub_str = generate_expression(subject)
      let clauses_str =
        clauses |> list.map(generate_case_clause) |> string.join("\n    ")
      "case " <> sub_str <> " {\n    " <> clauses_str <> "\n  }"
    }

    ast.TupleExpr(elements) -> {
      let elements_str =
        elements |> list.map(generate_expression) |> string.join(", ")
      "#(" <> elements_str <> ")"
    }

    ast.TupleIndexExpr(tuple, idx) -> {
      generate_expression(tuple) <> "." <> int.to_string(idx)
    }

    ast.AnonFnExpr(params, body) -> {
      let params_str = params |> list.map(generate_pattern) |> string.join(", ")
      let body_str =
        body |> list.map(generate_statement) |> string.join("\n      ")
      "fn(" <> params_str <> ") {\n      " <> body_str <> "\n    }"
    }

    // Record Field Access
    ast.RecordAccessExpr(base, field) -> {
      generate_expression(base) <> "." <> field
    }

    // Struct update syntax (e.g., Team(team | coach: new_coach))
    ast.RecordUpdateExpr(name, base, updates) -> {
      let base_str = generate_expression(base)

      case updates {
        [] -> name <> "(.." <> base_str <> ")"
        _ -> {
          let updates_str =
            updates
            |> list.map(fn(arg) {
              let #(label, expr) = arg
              case label {
                "" -> generate_expression(expr)
                lbl -> lbl <> ": " <> generate_expression(expr)
              }
            })
            |> string.join(", ")
          name <> "(.." <> base_str <> ", " <> updates_str <> ")"
        }
      }
    }

    ast.TryExpr(_) ->
      panic as "The ? operator can only be used directly on assignments or standalone statements in Bea"
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

fn generate_cond(clauses: List(ast.CondClause)) -> String {
  case clauses {
    [] -> "panic as \"No cond clause matched\""
    [ast.CondClause(cond_expr, body_expr), ..rest] -> {
      // SYNTACTIC SUGAR: If they use `True ->` or `_ ->`, just output the body natively!
      case cond_expr {
        ast.IdentExpr("True") | ast.IdentExpr("_") ->
          generate_expression(body_expr)
        _ -> {
          let c = generate_expression(cond_expr)
          let b = generate_expression(body_expr)
          let r = generate_cond(rest)
          "case "
          <> c
          <> " {\n  True -> "
          <> b
          <> "\n  False -> {\n    "
          <> r
          <> "\n  }\n}"
        }
      }
    }
  }
}

fn generate_case_clause(clause: ast.CaseClause) -> String {
  let pat_str =
    clause.patterns |> list.map(generate_expression) |> string.join(" | ")

  let guard_str = case clause.guard {
    [] -> ""
    [g] -> " if " <> generate_expression(g)
    _ -> ""
  }

  let body_str = generate_expression(clause.body)
  pat_str <> guard_str <> " -> " <> body_str
}
