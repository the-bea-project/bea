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

  // 2. Identify all single-variant custom types (irrefutable records)
  let single_variants = collect_single_variants(statements)

  // 3. Generate the main body code
  let body_str =
    statements
    |> list.filter(fn(s) {
      case s {
        ast.ImportStmt(_) -> False
        _ -> True
      }
    })
    |> list.map(fn(s) { generate_statement(s, single_variants) })
    |> string.join("\n\n")

  // 4. Stitch them together
  case imports_str {
    "" -> body_str
    _ -> imports_str <> "\n\n" <> body_str
  }
}

// Scans statements for custom types that have exactly one variant constructor
fn collect_single_variants(statements: List(ast.Statement)) -> Set(String) {
  list.fold(statements, set.new(), fn(acc, stmt) {
    case stmt {
      ast.CustomTypeStmt(_is_pub, _name, [ast.TypeVariant(variant_name, _)]) ->
        set.insert(acc, variant_name)
      _ -> acc
    }
  })
}

// Determines if a pattern is guaranteed to match without runtime assertions
fn is_irrefutable_pattern(
  expr: ast.Expr,
  single_variants: Set(String),
) -> Bool {
  case expr {
    // Variable binding or discard (e.g. `x`, `_`, `user_id`)
    ast.IdentExpr(name) -> {
      let first = string.slice(name, 0, 1)
      case first == string.lowercase(first) {
        True -> True
        False -> set.contains(single_variants, name)
      }
    }

    // Typed pattern (e.g. `x: Int`)
    ast.TypedExpr(inner, _) -> is_irrefutable_pattern(inner, single_variants)

    // Alias pattern (e.g. `pattern as name`)
    ast.AliasExpr(pattern, _) ->
      is_irrefutable_pattern(pattern, single_variants)

    // Tuple pattern: irrefutable if every sub-element is irrefutable
    ast.TupleExpr(elements) ->
      list.all(elements, fn(el) { is_irrefutable_pattern(el, single_variants) })

    // Constructor pattern: irrefutable if it has only one variant and all args are irrefutable
    ast.CallExpr(name, args) -> {
      case set.contains(single_variants, name) {
        True ->
          list.all(args, fn(arg) {
            let #(_label, val) = arg
            is_irrefutable_pattern(val, single_variants)
          })
        False -> False
      }
    }

    // Literals, lists, and multi-variant constructors are refutable
    _ -> False
  }
}

// Recursively walks a list of statements to collect required imports
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

fn analyze_statement(stmt: ast.Statement, imports: Set(String)) -> Set(String) {
  case stmt {
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
        [ast.ReturnStmt(_)] -> set.insert(base_imports, "gleam/bool")
        _ -> base_imports
      }
    }

    ast.ImportStmt(path) -> set.insert(imports, path)
    ast.AssignStmt(_, ast.TryExpr(_)) -> set.insert(imports, "gleam/result")
    ast.ExprStmt(ast.TryExpr(_)) -> set.insert(imports, "gleam/result")

    _ -> imports
  }
}

fn generate_statement(
  stmt: ast.Statement,
  single_variants: Set(String),
) -> String {
  case stmt {
    // Module-level Constants
    ast.ConstStmt(is_pub, name, value) -> {
      let pub_prefix = case is_pub {
        True -> "pub "
        False -> ""
      }
      pub_prefix
      <> "const "
      <> name
      <> " = "
      <> generate_expression(value, single_variants)
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
                    _ -> f_name <> ": " <> f_type
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

    // Function Definitions
    ast.DefStmt(is_pub, name, return_type, clauses) -> {
      let pub_prefix = case is_pub {
        True -> "pub "
        False -> ""
      }

      let ret_str = case return_type {
        "" -> ""
        t -> " -> " <> t
      }

      case clauses {
        [ast.Clause(params, [], body)] -> {
          case is_simple_params(params) {
            True -> {
              let params_str =
                params |> list.map(generate_pattern) |> string.join(", ")
              let body_str =
                body
                |> list.map(fn(s) { generate_statement(s, single_variants) })
                |> string.join("\n  ")
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
            False ->
              generate_multi_clause(
                is_pub,
                name,
                return_type,
                clauses,
                single_variants,
              )
          }
        }
        _ ->
          generate_multi_clause(
            is_pub,
            name,
            return_type,
            clauses,
            single_variants,
          )
      }
    }

    // Return statement
    ast.ReturnStmt(expr) -> generate_expression(expr, single_variants)

    // Error Propagation Assignment (The ? Operator)
    ast.AssignStmt(pattern_expr, ast.TryExpr(value_expr)) -> {
      let pat_str = generate_pattern(pattern_expr)
      let val_str = generate_expression(value_expr, single_variants)
      "use " <> pat_str <> " <- result.try(" <> val_str <> ")"
    }

    // Optimized Assignment: Emits `let` if irrefutable, otherwise `let assert`
    ast.AssignStmt(pattern_expr, value_expr) -> {
      let pat_str = generate_pattern(pattern_expr)
      let val_str = generate_expression(value_expr, single_variants)
      case is_irrefutable_pattern(pattern_expr, single_variants) {
        True -> "let " <> pat_str <> " = " <> val_str
        False -> "let assert " <> pat_str <> " = " <> val_str
      }
    }

    // Error Propagation Standalone Expression
    ast.ExprStmt(ast.TryExpr(value_expr)) -> {
      "use _ <- result.try("
      <> generate_expression(value_expr, single_variants)
      <> ")"
    }

    // Standard Standalone Expression
    ast.ExprStmt(expr) -> generate_expression(expr, single_variants)

    // If / Else Statements
    ast.IfStmt(condition, body, else_body) -> {
      let cond_str = generate_expression(condition, single_variants)

      case body {
        [ast.ReturnStmt(ret_expr)] -> {
          let ret_str = generate_expression(ret_expr, single_variants)
          let guard_str =
            "use <- bool.guard(when: "
            <> cond_str
            <> ", return: "
            <> ret_str
            <> ")"

          case else_body {
            [] -> guard_str
            _ -> {
              let else_str =
                else_body
                |> list.map(fn(s) { generate_statement(s, single_variants) })
                |> string.join("\n  ")
              guard_str <> "\n  " <> else_str
            }
          }
        }

        _ -> {
          let body_str =
            body
            |> list.map(fn(s) { generate_statement(s, single_variants) })
            |> string.join("\n      ")

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
                |> list.map(fn(s) { generate_statement(s, single_variants) })
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
  single_variants: Set(String),
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
  let valid_clauses = list.filter(clauses, fn(c) { c.body != [] })

  let cases_str =
    valid_clauses
    |> list.map(fn(c) { generate_clause_arm(c, single_variants) })
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

fn is_simple_params(params: List(ast.Expr)) -> Bool {
  list.all(params, fn(p) {
    case p {
      ast.IdentExpr(_) -> True
      ast.TypedExpr(ast.IdentExpr(_), _) -> True
      _ -> False
    }
  })
}

fn generate_clause_arm(
  clause: ast.Clause,
  single_variants: Set(String),
) -> String {
  let ast.Clause(params, guard, body) = clause
  let pattern_str = params |> list.map(generate_pattern) |> string.join(", ")

  let guard_str = case guard {
    [] -> ""
    [g] -> " if " <> generate_expression(g, single_variants)
    _ -> ""
  }

  let body_str =
    body
    |> list.map(fn(s) { generate_statement(s, single_variants) })
    |> string.join("\n      ")

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

fn generate_expression(expr: ast.Expr, single_variants: Set(String)) -> String {
  case expr {
    ast.IntExpr(val) -> int.to_string(val)
    ast.FloatExpr(val) -> float.to_string(val)
    ast.StringExpr(val) -> "\"" <> val <> "\""
    ast.IdentExpr(name) -> name

    ast.AliasExpr(pattern, name) -> {
      generate_expression(pattern, single_variants) <> " as " <> name
    }

    ast.UnaryExpr("not", inner) ->
      "!" <> generate_expression(inner, single_variants)
    ast.UnaryExpr(op, _) -> panic as { "Unsupported unary operator: " <> op }

    ast.TypedExpr(inner, type_name) ->
      generate_expression(inner, single_variants) <> ": " <> type_name

    ast.BinaryExpr(left, op, right) -> {
      let gleam_op = case op {
        "and" -> "&&"
        "or" -> "||"
        other -> other
      }

      "{"
      <> generate_expression(left, single_variants)
      <> " "
      <> gleam_op
      <> " "
      <> generate_expression(right, single_variants)
      <> "}"
    }

    ast.CallExpr(name, args) -> {
      let args_str =
        args
        |> list.map(fn(arg) {
          let #(label, e) = arg
          case label {
            "" -> generate_expression(e, single_variants)
            lbl -> lbl <> ": " <> generate_expression(e, single_variants)
          }
        })
        |> string.join(", ")
      name <> "(" <> args_str <> ")"
    }

    ast.EchoExpr(inner) ->
      "{ echo " <> generate_expression(inner, single_variants) <> " }"

    ast.ListExpr(elements) -> {
      let elements_str =
        elements
        |> list.map(fn(e) { generate_expression(e, single_variants) })
        |> string.join(", ")
      "[" <> elements_str <> "]"
    }

    ast.ListConsExpr(head, tail) -> {
      "["
      <> generate_expression(head, single_variants)
      <> ", .."
      <> generate_expression(tail, single_variants)
      <> "]"
    }

    ast.CondExpr(clauses) -> generate_cond(clauses, single_variants)

    ast.CaseExpr(subject, clauses) -> {
      let sub_str = generate_expression(subject, single_variants)
      let clauses_str =
        clauses
        |> list.map(fn(c) { generate_case_clause(c, single_variants) })
        |> string.join("\n    ")
      "case " <> sub_str <> " {\n    " <> clauses_str <> "\n  }"
    }

    ast.TupleExpr(elements) -> {
      let elements_str =
        elements
        |> list.map(fn(e) { generate_expression(e, single_variants) })
        |> string.join(", ")
      "#(" <> elements_str <> ")"
    }

    ast.TupleIndexExpr(tuple, idx) -> {
      generate_expression(tuple, single_variants) <> "." <> int.to_string(idx)
    }

    ast.MapExpr(pairs) -> {
      let pairs_str =
        pairs
        |> list.map(fn(p) {
          let #(k, v) = p
          "#("
          <> generate_expression(k, single_variants)
          <> ", "
          <> generate_expression(v, single_variants)
          <> ")"
        })
        |> string.join(", ")
      "dict.from_list([" <> pairs_str <> "])"
    }

    ast.AnonFnExpr(params, body) -> {
      let params_str = params |> list.map(generate_pattern) |> string.join(", ")
      let body_str =
        body
        |> list.map(fn(s) { generate_statement(s, single_variants) })
        |> string.join("\n      ")
      "fn(" <> params_str <> ") {\n      " <> body_str <> "\n    }"
    }

    ast.RecordAccessExpr(base, field) -> {
      generate_expression(base, single_variants) <> "." <> field
    }

    ast.RecordUpdateExpr(name, base, updates) -> {
      let base_str = generate_expression(base, single_variants)

      case updates {
        [] -> name <> "(.." <> base_str <> ")"
        _ -> {
          let updates_str =
            updates
            |> list.map(fn(arg) {
              let #(label, e) = arg
              case label {
                "" -> generate_expression(e, single_variants)
                lbl -> lbl <> ": " <> generate_expression(e, single_variants)
              }
            })
            |> string.join(", ")
          name <> "(.." <> base_str <> ", " <> updates_str <> ")"
        }
      }
    }

    ast.BlockExpr(stmts) -> {
      let stmts_str =
        stmts
        |> list.map(fn(s) { generate_statement(s, single_variants) })
        |> string.join("\n      ")
      "{\n      " <> stmts_str <> "\n    }"
    }

    ast.TryExpr(_) ->
      panic as "The ? operator can only be used directly on assignments or standalone statements in Bea"

    ast.PanicExpr -> "panic"

    ast.PanicAsExpr(msg) ->
      "panic as " <> generate_expression(msg, single_variants)
  }
}

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

fn generate_cond(
  clauses: List(ast.CondClause),
  single_variants: Set(String),
) -> String {
  case clauses {
    [] -> "panic as \"No cond clause matched\""
    [ast.CondClause(cond_expr, body_expr), ..rest] -> {
      case cond_expr {
        ast.IdentExpr("True") | ast.IdentExpr("_") ->
          generate_expression(body_expr, single_variants)
        _ -> {
          let c = generate_expression(cond_expr, single_variants)
          let b = generate_expression(body_expr, single_variants)
          let r = generate_cond(rest, single_variants)
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

fn generate_case_clause(
  clause: ast.CaseClause,
  single_variants: Set(String),
) -> String {
  let pat_str =
    clause.patterns
    |> list.map(fn(p) { generate_expression(p, single_variants) })
    |> string.join(" | ")

  let guard_str = case clause.guard {
    [] -> ""
    [g] -> " if " <> generate_expression(g, single_variants)
    _ -> ""
  }

  let body_str = generate_expression(clause.body, single_variants)
  pat_str <> guard_str <> " -> " <> body_str
}
