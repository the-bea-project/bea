// src/bea/desugar.gleam

import bea/ast
import gleam/int
import gleam/list

pub fn process(program: ast.Program) -> ast.Program {
  let #(final_counter, new_stmts) = hoist_statements(program.statements, 0)

  // If the counter is > 0, we used the ? operator! 
  // Inject the import so the codegen automatically picks it up.
  let final_stmts = case final_counter > 0 {
    True -> [ast.ImportStmt("gleam/result"), ..new_stmts]
    False -> new_stmts
  }

  ast.Program(final_stmts)
}

// Folds over a list of statements, threading the counter, and flattens the result
fn hoist_statements(
  stmts: List(ast.Statement),
  counter: Int,
) -> #(Int, List(ast.Statement)) {
  let #(final_counter, nested_stmts) =
    list.map_fold(stmts, counter, hoist_statement)
  #(final_counter, list.flatten(nested_stmts))
}

fn hoist_statement(
  counter: Int,
  stmt: ast.Statement,
) -> #(Int, List(ast.Statement)) {
  case stmt {
    ast.AssignStmt(pat, ast.TryExpr(inner)) -> {
      let #(c1, hoisted, new_inner) = hoist_expr(inner, counter)
      let final_stmt = ast.AssignStmt(pat, ast.TryExpr(new_inner))
      // Track that we used the ? operator!
      #(c1 + 1, list.append(hoisted, [final_stmt]))
    }

    // Standard Assignment: Check if the value has nested TryExprs
    ast.AssignStmt(pat, val) -> {
      let #(c1, hoisted, new_val) = hoist_expr(val, counter)
      #(c1, list.append(hoisted, [ast.AssignStmt(pat, new_val)]))
    }

    // ExprStmt: Standalone expressions (e.g. function calls)
    ast.ExprStmt(expr) -> {
      // If it's exactly `expr?` on its own line, leave it!
      case expr {
        ast.TryExpr(inner) -> {
          let #(c1, hoisted, new_inner) = hoist_expr(inner, counter)
          // Track that we used the ? operator!
          #(
            c1 + 1,
            list.append(hoisted, [ast.ExprStmt(ast.TryExpr(new_inner))]),
          )
        }
        _ -> {
          let #(c1, hoisted, new_expr) = hoist_expr(expr, counter)
          #(c1, list.append(hoisted, [ast.ExprStmt(new_expr)]))
        }
      }
    }

    // Return Statements
    ast.ReturnStmt(expr) -> {
      let #(c1, hoisted, new_expr) = hoist_expr(expr, counter)
      #(c1, list.append(hoisted, [ast.ReturnStmt(new_expr)]))
    }

    // --- Traversing Function Definitions ---
    ast.DefStmt(is_pub, name, ret_type, clauses) -> {
      // Loop over every clause in the function (e.g. multi-clause functions)
      let #(final_counter, new_clauses) =
        list.map_fold(clauses, counter, fn(curr_c, clause) {
          let ast.Clause(params, guard, body) = clause

          // Recursively hoist everything inside the function's body!
          let #(next_c, new_body) = hoist_statements(body, curr_c)
          #(next_c, ast.Clause(params, guard, new_body))
        })

      #(final_counter, [ast.DefStmt(is_pub, name, ret_type, new_clauses)])
    }

    // Base case for things like ConstStmt or ImportStmt that don't need hoisting
    _ -> #(counter, [stmt])
  }
}

fn hoist_expr(
  expr: ast.Expr,
  counter: Int,
) -> #(Int, List(ast.Statement), ast.Expr) {
  case expr {
    // --- THE MAGIC SAUCE: The nested TryExpr ---
    ast.TryExpr(inner) -> {
      // 1. Hoist anything inside it first
      let #(c1, hoisted_inner, new_inner) = hoist_expr(inner, counter)

      // 2. Generate a fresh, unique variable name
      let tmp_name = "bea_tmp_" <> int.to_string(c1)

      // 3. Create the hoisted statement: _bea_tmp_N = new_inner?
      let hoist_stmt =
        ast.AssignStmt(ast.IdentExpr(tmp_name), ast.TryExpr(new_inner))

      // 4. Return the temporary variable as the NEW expression!
      let all_hoisted = list.append(hoisted_inner, [hoist_stmt])
      #(c1 + 1, all_hoisted, ast.IdentExpr(tmp_name))
    }

    // --- Traversing other expressions ---
    ast.BinaryExpr(left, op, right) -> {
      let #(c1, hl, new_l) = hoist_expr(left, counter)
      let #(c2, hr, new_r) = hoist_expr(right, c1)
      #(c2, list.append(hl, hr), ast.BinaryExpr(new_l, op, new_r))
    }

    ast.CallExpr(name, args) -> {
      // Fold over the arguments to catch any ? inside function parameters!
      let #(final_counter, all_hoisted, new_args) =
        list.fold(args, #(counter, [], []), fn(acc, arg) {
          let #(curr_c, curr_h, curr_args) = acc
          let #(label, arg_expr) = arg
          let #(next_c, new_h, new_expr) = hoist_expr(arg_expr, curr_c)
          #(
            next_c,
            list.append(curr_h, new_h),
            list.append(curr_args, [#(label, new_expr)]),
          )
        })
      #(final_counter, all_hoisted, ast.CallExpr(name, new_args))
    }

    // --- Traversing If Expressions ---
    ast.IfExpr(cond, body, else_body) -> {
      let #(c1, hoisted_cond, new_cond) = hoist_expr(cond, counter)
      let #(c2, new_body) = hoist_statements(body, c1)
      let #(c3, new_else) = hoist_statements(else_body, c2)

      let final_expr = ast.IfExpr(new_cond, new_body, new_else)
      #(c3, hoisted_cond, final_expr)
    }

    // --- Traversing Case Expressions ---
    ast.CaseExpr(subject, clauses) -> {
      // 1. Hoist the subject first (in case it has a ?)
      let #(c1, hoisted_sub, new_subject) = hoist_expr(subject, counter)

      // 2. Traverse all the case clauses
      let #(final_counter, new_clauses) =
        list.map_fold(clauses, c1, fn(curr_c, clause) {
          let ast.CaseClause(patterns, guard, body) = clause

          // Hoist the ? out of the clause's body
          let #(next_c, body_hoisted, new_body_expr) = hoist_expr(body, curr_c)

          // If we hoisted something, wrap it all in a BlockExpr!
          let final_body = case body_hoisted {
            [] -> new_body_expr
            _ -> {
              let all_stmts =
                list.append(body_hoisted, [ast.ExprStmt(new_body_expr)])
              ast.BlockExpr(all_stmts)
            }
          }

          #(next_c, ast.CaseClause(patterns, guard, final_body))
        })

      #(final_counter, hoisted_sub, ast.CaseExpr(new_subject, new_clauses))
    }

    // --- Traversing Block Expressions ---
    ast.BlockExpr(stmts) -> {
      // Just reuse your hoist_statements helper!
      let #(next_c, new_stmts) = hoist_statements(stmts, counter)
      #(next_c, [], ast.BlockExpr(new_stmts))
    }

    // --- Traversing Panics ---
    ast.PanicAsExpr(msg) -> {
      let #(c1, hoisted, new_msg) = hoist_expr(msg, counter)
      #(c1, hoisted, ast.PanicAsExpr(new_msg))
    }

    ast.PanicExpr -> #(counter, [], expr)

    // Base cases (IntExpr, IdentExpr, StringExpr) have no nested expressions.
    _ -> #(counter, [], expr)
  }
}
