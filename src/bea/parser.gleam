// src/bea/parser.gleam

import bea/ast
import bea/lexer.{type Token}
import gleam/list
import gleam/string

pub fn parse(tokens: List(Token)) -> ast.Program {
  let statements = parse_statements(tokens, [])
  ast.Program(list.reverse(statements))
}

fn parse_statements(
  tokens: List(Token),
  acc: List(ast.Statement),
) -> List(ast.Statement) {
  case tokens {
    [lexer.Eof] | [] -> collapse_clauses(list.reverse(acc))

    // Handle `pub def`
    [lexer.Pub, lexer.Def, lexer.Ident(name), lexer.LParen, ..rest] -> {
      parse_def(True, name, rest, acc)
    }

    // Handle private `def`
    [lexer.Def, lexer.Ident(name), lexer.LParen, ..rest] -> {
      parse_def(False, name, rest, acc)
    }

    [lexer.Import, ..rest] -> {
      let #(path, after_path) = parse_import_path(rest, "")
      parse_statements(after_path, [ast.ImportStmt(path), ..acc])
    }

    // Handle `pub type`
    [lexer.Pub, lexer.Type, lexer.TypeIdent(name), ..rest] -> {
      parse_type_definition(True, name, rest, acc)
    }

    // Handle private `type`
    [lexer.Type, lexer.TypeIdent(name), ..rest] -> {
      parse_type_definition(False, name, rest, acc)
    }

    // Handle `pub const`
    [lexer.Pub, lexer.Const, lexer.Ident(name), lexer.Eq, ..rest] -> {
      let #(val_expr, after_val) = parse_expression(rest)
      let stmt = ast.ConstStmt(True, name, val_expr)
      parse_statements(after_val, [stmt, ..acc])
    }

    // Handle private `const`
    [lexer.Const, lexer.Ident(name), lexer.Eq, ..rest] -> {
      let #(val_expr, after_val) = parse_expression(rest)
      let stmt = ast.ConstStmt(False, name, val_expr)
      parse_statements(after_val, [stmt, ..acc])
    }

    [_, ..rest] -> parse_statements(rest, acc)
  }
}

// Parses function parameters as full pattern expressions (e.g. 0, "admin", or x)
fn parse_pattern_params(
  tokens: List(Token),
  acc: List(ast.Expr),
) -> #(List(ast.Expr), List(Token)) {
  case tokens {
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)
    _ -> {
      // 1. Parse the first expression (this could be a label, or the actual param)
      let #(expr, after_expr) = parse_expression(tokens)

      // 1b. INTERCEPT LABEL: If we have an identifier followed directly by another identifier!
      // (e.g., `target_color` followed by `color`)
      let #(actual_expr, after_name) = case expr, after_expr {
        ast.IdentExpr(label), [lexer.Ident(name), ..rest2] -> {
          #(ast.LabelExpr(label, ast.IdentExpr(name)), rest2)
        }
        _, _ -> #(expr, after_expr)
      }

      // 2. Intercept type annotations (e.g., `: Int`)
      let #(final_expr, after_type) = case after_name {
        [lexer.Colon, ..rest2] -> {
          let #(type_str, rest3) = parse_type(rest2)
          #(ast.TypedExpr(actual_expr, type_str), rest3)
        }
        _ -> #(actual_expr, after_name)
      }

      // 3. Look for the comma or closing parenthesis
      case after_type {
        [lexer.Comma, ..rest3] ->
          parse_pattern_params(rest3, [final_expr, ..acc])
        [lexer.RParen, ..rest3] -> #(list.reverse([final_expr, ..acc]), rest3)
        _ -> panic as "Syntax Error: Expected ',' or ')' in parameters"
      }
    }
  }
}

// Helper to merge consecutive DefStmt definitions with identical names
fn collapse_clauses(statements: List(ast.Statement)) -> List(ast.Statement) {
  case statements {
    [] -> []

    [
      ast.DefStmt(p1, name1, ret1, clauses1),
      ast.DefStmt(p2, name2, ret2, clauses2),
      ..rest
    ]
      if name1 == name2
    -> {
      // 1. If ANY clause is pub, make the whole function pub
      let is_pub = p1 || p2

      // 2. Keep whichever return type isn't an empty string
      let return_type = case ret1 {
        "" -> ret2
        _ -> ret1
      }

      collapse_clauses([
        ast.DefStmt(is_pub, name1, return_type, list.append(clauses1, clauses2)),
        ..rest
      ])
    }

    [stmt, ..rest] -> [stmt, ..collapse_clauses(rest)]
  }
}

// Parses a primary expression AND any tightly bound postfix operators (like ? or .)
fn parse_operand(tokens: List(Token)) -> #(ast.Expr, List(Token)) {
  let #(expr, rest) = parse_primary(tokens)
  continue_postfix(expr, rest)
}

// Loops to catch consecutive postfix operators (e.g., user.team.id?)
fn continue_postfix(
  left: ast.Expr,
  tokens: List(Token),
) -> #(ast.Expr, List(Token)) {
  case tokens {
    [lexer.Dot, lexer.IntLit(idx), ..rest] ->
      continue_postfix(ast.TupleIndexExpr(left, idx), rest)
    [lexer.Dot, lexer.Ident(field), ..rest] ->
      continue_postfix(ast.RecordAccessExpr(left, field), rest)
    [lexer.As, lexer.Ident(alias_name), ..rest] ->
      continue_postfix(ast.AliasExpr(left, alias_name), rest)
    [lexer.Question, ..rest] -> continue_postfix(ast.TryExpr(left), rest)
    _ -> #(left, tokens)
  }
}

fn parse_primary(tokens: List(Token)) -> #(ast.Expr, List(Token)) {
  case tokens {
    [lexer.IntLit(val), ..rest] -> #(ast.IntExpr(val), rest)
    [lexer.FloatLit(val), ..rest] -> #(ast.FloatExpr(val), rest)
    [lexer.StringLit(val), ..rest] -> #(ast.StringExpr(val), rest)

    [lexer.Not, ..rest] -> {
      let #(inner_expr, after_inner) = parse_primary(rest)
      #(ast.UnaryExpr("!", inner_expr), after_inner)
    }

    // Handle the '!' symbol
    [lexer.Bang, ..rest] -> {
      let #(inner_expr, after_inner) = parse_primary(rest)
      #(ast.UnaryExpr("!", inner_expr), after_inner)
    }

    // Anonymous functions (e.g., fn(x) { x.1 == 42 })
    [lexer.Fn, lexer.LParen, ..rest] -> {
      let #(params, after_params) = parse_pattern_params(rest, [])
      let assert [lexer.LBrace, ..after_brace] = after_params
      let #(body, after_block) = parse_block(after_brace, [])
      #(ast.AnonFnExpr(params, body), after_block)
    }

    // Echo Expression
    [lexer.Echo, ..rest] -> {
      let #(expr, after_expr) = parse_expression(rest)
      #(ast.EchoExpr(expr), after_expr)
    }

    // Standard function calls (e.g., calculate(10))
    [lexer.Ident(name), lexer.LParen, ..rest] -> {
      let #(args, after_args) = parse_args(rest, [])
      #(ast.CallExpr(name, args), after_args)
    }

    // Constructor calls AND Record Updates
    [lexer.TypeIdent(name), lexer.LParen, ..rest] -> {
      case rest {
        // Empty constructor: e.g., Chill()
        [lexer.RParen, ..after_parens] -> #(
          ast.CallExpr(name, []),
          after_parens,
        )

        _ -> {
          // Tentatively parse the first element to see if a Pipe follows
          let #(first_expr, after_first) = parse_expression(rest)

          case after_first {
            // Path A: It's an Elixir-style record update! e.g., Team(team | coach:)
            [lexer.Pipe, ..rest2] -> {
              let #(updates, after_updates) = parse_args(rest2, [])
              #(ast.RecordUpdateExpr(name, first_expr, updates), after_updates)
            }

            // Path B: Standard constructor call. 
            // We backtrack by passing the original `rest` so parse_args handles labels!
            _ -> {
              let #(args, after_args) = parse_args(rest, [])
              #(ast.CallExpr(name, args), after_args)
            }
          }
        }
      }
    }

    // Intercept Lists
    [lexer.LBracket, ..rest] -> parse_list_elements(rest, [])

    // Parentheses: Grouping OR Tuples!
    [lexer.LParen, ..rest] -> {
      let #(elements, after_parens) = parse_tuple_or_group(rest, [])
      case elements {
        [] -> #(ast.IdentExpr("Nil"), after_parens)
        // () evaluates to Nil
        [single] -> #(single, after_parens)
        // (1 + 2) evaluates to 3
        _ -> #(ast.TupleExpr(elements), after_parens)
        // (1, 2) evaluates to a Tuple
      }
    }

    // Catch-all block expressions! { ... }
    [lexer.LBrace, ..rest] -> {
      let #(stmts, after_block) = parse_block(rest, [])
      #(ast.BlockExpr(stmts), after_block)
    }

    // Map Literals: %{ key: value }
    [lexer.Percent, lexer.LBrace, ..rest] -> {
      let #(pairs, after_brace) = parse_map_pairs(rest, [])
      #(ast.MapExpr(pairs), after_brace)
    }

    // For module calls like `io.println()`
    [lexer.Ident(module), lexer.Dot, lexer.Ident(name), lexer.LParen, ..rest] -> {
      let #(args, after_args) = parse_args(rest, [])
      // Combine them into a single CallExpr string for the backend
      #(ast.CallExpr(module <> "." <> name, args), after_args)
    }

    // Catch the wildcard underscore
    [lexer.Underscore, ..rest] -> #(ast.IdentExpr("_"), rest)

    // If / Else statements
    [lexer.If, ..rest] -> {
      let #(if_expr, after_if) = parse_if(rest)
      #(if_expr, after_if)
    }

    // Parse cond { ... }
    [lexer.Cond, lexer.LBrace, ..rest] -> {
      let #(clauses, after_cond) = parse_cond_clauses(rest, [])
      #(ast.CondExpr(clauses), after_cond)
    }

    // Parse case subject { ... }
    [lexer.Case, ..rest] -> {
      let #(subject, after_sub) = parse_expression(rest)
      let assert [lexer.LBrace, ..after_brace] = after_sub
      let #(clauses, after_case) = parse_case_clauses(after_brace, [])
      #(ast.CaseExpr(subject, clauses), after_case)
    }

    // Standalone variables
    [lexer.Ident(name), ..rest] -> #(ast.IdentExpr(name), rest)

    // Standalone constructors (e.g., True, False)
    [lexer.TypeIdent(name), ..rest] -> #(ast.IdentExpr(name), rest)

    // Catch `panic as "Message"`
    [lexer.Panic, lexer.As, ..rest] -> {
      let #(msg_expr, after_msg) = parse_expression(rest)
      #(ast.PanicAsExpr(msg_expr), after_msg)
    }

    // Catch standard `panic`
    [lexer.Panic, ..rest] -> {
      #(ast.PanicExpr, rest)
    }

    _ -> panic as "Syntax Error: Expected an expression"
  }
}

fn parse_expression(tokens: List(Token)) -> #(ast.Expr, List(Token)) {
  let #(left, after_left) = parse_operand(tokens)
  continue_expression(left, after_left)
}

// This helper lets us endlessly chain operators without breaking!
fn continue_expression(
  left: ast.Expr,
  after_left: List(Token),
) -> #(ast.Expr, List(Token)) {
  case after_left {
    // Tuple Indexing (e.g., coords.0 or get_tuple().1)
    [lexer.Dot, lexer.IntLit(idx), ..rest] -> {
      continue_expression(ast.TupleIndexExpr(left, idx), rest)
    }

    // Record Field Access (e.g., team.coach or team.coach.name)
    [lexer.Dot, lexer.Ident(field), ..rest] -> {
      continue_expression(ast.RecordAccessExpr(left, field), rest)
    }

    [lexer.Ident("as"), lexer.Ident(alias_name), ..rest] -> {
      continue_expression(ast.AliasExpr(left, alias_name), rest)
    }

    // The `?` Try Operator
    [lexer.Question, ..rest] -> {
      continue_expression(ast.TryExpr(left), rest)
    }

    // SYNTACTIC SUGAR: Wraps the ENTIRE left-hand pipeline inside the echo!
    [lexer.PipeRight, lexer.Echo, ..rest] -> {
      continue_expression(ast.EchoExpr(left), rest)
    }

    // Use parse_operand(rest)
    [lexer.PipeRight, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "|>", right), after_right)
    }
    [lexer.Plus, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "+", right), after_right)
    }
    [lexer.Minus, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "-", right), after_right)
    }
    [lexer.Star, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "*", right), after_right)
    }
    [lexer.Slash, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "/", right), after_right)
    }
    [lexer.PlusDot, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "+.", right), after_right)
    }
    [lexer.MinusDot, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "-.", right), after_right)
    }
    [lexer.StarDot, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "*.", right), after_right)
    }
    [lexer.SlashDot, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "/.", right), after_right)
    }
    [lexer.Greater, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, ">", right), after_right)
    }
    [lexer.GreaterEq, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, ">=", right), after_right)
    }
    [lexer.Less, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "<", right), after_right)
    }
    [lexer.LessEq, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "<=", right), after_right)
    }
    [lexer.EqEq, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "==", right), after_right)
    }
    [lexer.BangEq, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "!=", right), after_right)
    }
    [lexer.Concat, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "<>", right), after_right)
    }
    // Translate `and` directly to `&&`
    [lexer.And, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "&&", right), after_right)
    }
    // Translate `or` directly to `||`
    [lexer.Or, ..rest] -> {
      let #(right, after_right) = parse_operand(rest)
      continue_expression(ast.BinaryExpr(left, "||", right), after_right)
    }

    // Catch-all: no operators found, return the expression as-is
    _ -> #(left, after_left)
  }
}

fn parse_block(
  tokens: List(Token),
  acc: List(ast.Statement),
) -> #(List(ast.Statement), List(Token)) {
  case tokens {
    [lexer.RBrace, ..rest] -> #(list.reverse(acc), rest)

    [lexer.Return, ..rest] -> {
      let #(expr, after_expr) = parse_expression(rest)
      parse_block(after_expr, [ast.ReturnStmt(expr), ..acc])
    }

    // Catch-all: Standalone expressions & assignments
    _ -> {
      // Parse whatever is on the left
      let #(expr, after_expr) = parse_expression(tokens)

      case after_expr {
        // If the next token is '=', it's an assignment!
        [lexer.Eq, ..rest] -> {
          let #(val_expr, after_val) = parse_expression(rest)
          parse_block(after_val, [ast.AssignStmt(expr, val_expr), ..acc])
        }

        // Otherwise, it's just a normal standalone expression
        _ -> {
          parse_block(after_expr, [ast.ExprStmt(expr), ..acc])
        }
      }
    }
  }
}

fn parse_args(
  tokens: List(Token),
  acc: List(#(String, ast.Expr)),
) -> #(List(#(String, ast.Expr)), List(Token)) {
  case tokens {
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)

    // 1. Shorthand label with a comma: `Coach(name:, ...)`
    [lexer.Ident(label), lexer.Colon, lexer.Comma, ..rest] -> {
      parse_args(rest, [#(label, ast.IdentExpr(label)), ..acc])
    }

    // 2. Shorthand label closing the call: `Coach(name:)`
    [lexer.Ident(label), lexer.Colon, lexer.RParen, ..rest] -> {
      #(list.reverse([#(label, ast.IdentExpr(label)), ..acc]), rest)
    }

    // 3. Explicit label: `name: "Alice"`
    [lexer.Ident(label), lexer.Colon, ..rest] -> {
      let #(expr, after_expr) = parse_expression(rest)
      consume_arg_separator(after_expr, [#(label, expr), ..acc])
    }

    // 4. Standard unlabeled argument: `"Alice"`
    _ -> {
      let #(expr, after_expr) = parse_expression(tokens)
      consume_arg_separator(after_expr, [#("", expr), ..acc])
    }
  }
}

// Helper to look for commas or closing parentheses between arguments
fn consume_arg_separator(
  tokens: List(Token),
  acc: List(#(String, ast.Expr)),
) -> #(List(#(String, ast.Expr)), List(Token)) {
  case tokens {
    [lexer.Comma, ..rest] -> parse_args(rest, acc)
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)
    // Handle partial struct matching `| _ )`
    [lexer.Pipe, lexer.Underscore, lexer.RParen, ..rest] -> {
      // Secretly inject Gleam's `..` into the AST!
      let partial_marker = #("", ast.IdentExpr(".."))
      #(list.reverse([partial_marker, ..acc]), rest)
    }
    _ -> panic as "Syntax Error: Expected ',' or ')' in function arguments"
  }
}

fn parse_list_elements(
  tokens: List(Token),
  acc: List(ast.Expr),
) -> #(ast.Expr, List(Token)) {
  case tokens {
    // Empty list []
    [lexer.RBracket, ..rest] -> #(ast.ListExpr(list.reverse(acc)), rest)

    _ -> {
      let #(expr, after_expr) = parse_expression(tokens)

      case after_expr {
        // Head / Tail Cons Syntax: [head | tail]
        [lexer.Pipe, ..rest] -> {
          let #(tail_expr, after_tail) = parse_expression(rest)
          case after_tail {
            [lexer.RBracket, ..final_rest] -> #(
              ast.ListConsExpr(expr, tail_expr),
              final_rest,
            )
            _ ->
              panic as "Syntax Error: Expected ']' after tail in list cons [head | tail]"
          }
        }

        // Standard comma-separated list item: [1, 2, 3]
        [lexer.Comma, ..rest] -> parse_list_elements(rest, [expr, ..acc])

        // End of standard list
        [lexer.RBracket, ..rest] -> #(
          ast.ListExpr(list.reverse([expr, ..acc])),
          rest,
        )

        _ -> panic as "Syntax Error: Expected ',', '|', or ']' in list"
      }
    }
  }
}

fn parse_if(tokens: List(Token)) -> #(ast.Expr, List(Token)) {
  let #(condition, after_cond) = parse_expression(tokens)
  let assert [lexer.LBrace, ..after_lbrace] = after_cond
  let #(body, after_body) = parse_block(after_lbrace, [])

  case after_body {
    [lexer.Else, lexer.If, ..after_elif] -> {
      let #(elif_expr, after_all) = parse_if(after_elif)
      // Wrap elif_expr in ExprStmt!
      #(ast.IfExpr(condition, body, [ast.ExprStmt(elif_expr)]), after_all)
    }
    [lexer.Else, lexer.LBrace, ..after_else_lbrace] -> {
      let #(else_body, after_else) = parse_block(after_else_lbrace, [])
      #(ast.IfExpr(condition, body, else_body), after_else)
    }
    _ -> #(ast.IfExpr(condition, body, []), after_body)
  }
}

fn parse_import_path(
  tokens: List(Token),
  acc: String,
) -> #(String, List(Token)) {
  case tokens {
    // Standard path parts
    [lexer.Ident(name), ..rest] -> parse_import_path(rest, acc <> name)
    [lexer.Slash, ..rest] -> parse_import_path(rest, acc <> "/")

    // Unqualified import blocks: .{type Order, Eq}
    [lexer.Dot, ..rest] -> parse_import_path(rest, acc <> ".")
    [lexer.LBrace, ..rest] -> parse_import_path(rest, acc <> "{")
    [lexer.RBrace, ..rest] -> parse_import_path(rest, acc <> "}")
    [lexer.Comma, ..rest] -> parse_import_path(rest, acc <> ", ")

    // The `type` keyword inside the braces
    [lexer.Type, ..rest] -> parse_import_path(rest, acc <> "type ")

    // Capitalized types (like Order, Some, None) inside the braces
    [lexer.TypeIdent(name), ..rest] -> parse_import_path(rest, acc <> name)

    // Stop parsing when we hit anything else (like a `def` or `pub`)
    _ -> #(acc, tokens)
  }
}

fn parse_def(
  is_pub: Bool,
  name: String,
  rest: List(Token),
  acc: List(ast.Statement),
) -> List(ast.Statement) {
  let #(params, after_params) = parse_pattern_params(rest, [])

  let #(return_type, after_ret) = case after_params {
    [lexer.Arrow, ..rest2] -> parse_type(rest2)
    _ -> #("", after_params)
  }

  // Intercept the `if` guard before the body block
  let #(guard, after_guard) = case after_ret {
    [lexer.If, ..rest_guard] -> {
      let #(g, after_g) = parse_expression(rest_guard)
      #([g], after_g)
    }
    _ -> #([], after_ret)
  }

  case after_guard {
    [lexer.LBrace, ..after_brace] -> {
      let #(body, after_block) = parse_block(after_brace, [])
      let clause = ast.Clause(params: params, guard: guard, body: body)
      let def_stmt =
        ast.DefStmt(
          is_pub: is_pub,
          name: name,
          return_type: return_type,
          clauses: [clause],
        )
      parse_statements(after_block, [def_stmt, ..acc])
    }

    // FUNCTION HEAD (No braces found)
    _ -> {
      let clause = ast.Clause(params: params, guard: [], body: [])
      let def_stmt =
        ast.DefStmt(
          is_pub: is_pub,
          name: name,
          return_type: return_type,
          clauses: [clause],
        )

      parse_statements(after_guard, [def_stmt, ..acc])
    }
  }
}

fn parse_cond_clauses(
  tokens: List(Token),
  acc: List(ast.CondClause),
) -> #(List(ast.CondClause), List(Token)) {
  case tokens {
    [lexer.RBrace, ..rest] -> #(list.reverse(acc), rest)
    _ -> {
      let #(cond_expr, after_cond) = parse_expression(tokens)
      let assert [lexer.Arrow, ..after_arrow] = after_cond
      let #(body_expr, after_body) = parse_expression(after_arrow)
      parse_cond_clauses(after_body, [
        ast.CondClause(cond_expr, body_expr),
        ..acc
      ])
    }
  }
}

fn parse_case_clauses(
  tokens: List(Token),
  acc: List(ast.CaseClause),
) -> #(List(ast.CaseClause), List(Token)) {
  case tokens {
    [lexer.RBrace, ..rest] -> #(list.reverse(acc), rest)
    _ -> {
      let #(patterns, after_patterns) = parse_patterns(tokens, [])

      // Look for the `if` guard
      let #(guard, after_guard) = case after_patterns {
        [lexer.If, ..rest_guard] -> {
          let #(g, after_g) = parse_expression(rest_guard)
          #([g], after_g)
        }
        _ -> #([], after_patterns)
      }

      let assert [lexer.Arrow, ..after_arrow] = after_guard
      let #(body, after_body) = parse_expression(after_arrow)
      parse_case_clauses(after_body, [
        ast.CaseClause(patterns, guard, body),
        ..acc
      ])
    }
  }
}

// Parses patterns separated by `|`
fn parse_patterns(
  tokens: List(Token),
  acc: List(ast.Expr),
) -> #(List(ast.Expr), List(Token)) {
  let #(pat, after_pat) = parse_expression(tokens)
  case after_pat {
    [lexer.Pipe, ..rest] -> parse_patterns(rest, [pat, ..acc])
    _ -> #(list.reverse([pat, ..acc]), after_pat)
  }
}

fn parse_tuple_or_group(
  tokens: List(Token),
  acc: List(ast.Expr),
) -> #(List(ast.Expr), List(Token)) {
  case tokens {
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)
    _ -> {
      let #(expr, after_expr) = parse_expression(tokens)

      case after_expr {
        [lexer.Comma, ..rest] -> parse_tuple_or_group(rest, [expr, ..acc])
        [lexer.RParen, ..rest] -> #(list.reverse([expr, ..acc]), rest)
        _ -> panic as "Syntax Error: Expected ',' or ')' in tuple/group"
      }
    }
  }
}

fn parse_type(tokens: List(Token)) -> #(String, List(Token)) {
  case tokens {
    // Function Types! e.g., fn(Int, String) -> Bool
    [lexer.Fn, lexer.LParen, ..rest] -> {
      // 1. Parse the parameter types (e.g. Int, String)
      let #(args, after_args) = parse_type_args(rest, [])

      // 2. Expect the arrow ->
      let assert [lexer.Arrow, ..after_arrow] = after_args

      // 3. Parse the return type
      let #(ret_type, after_ret) = parse_type(after_arrow)

      // 4. Stitch it together into a raw Gleam type string
      #("fn(" <> string.join(args, ", ") <> ") -> " <> ret_type, after_ret)
    }

    // e.g. List(Int) or Result(String, Error)
    [lexer.TypeIdent(name), lexer.LParen, ..rest] -> {
      let #(args, after_args) = parse_type_args(rest, [])
      #(name <> "(" <> string.join(args, ", ") <> ")", after_args)
    }
    // e.g. String or Int
    [lexer.TypeIdent(name), ..rest] -> #(name, rest)

    // e.g. Type variables like `a` in `List(a)`
    [lexer.Ident(name), ..rest] -> #(name, rest)

    // Tuple types! e.g. (String, Int)
    [lexer.LParen, ..rest] -> {
      let #(args, after_args) = parse_type_args(rest, [])
      // We immediately format it into Gleam's #(...) syntax so codegen doesn't have to!
      #("#(" <> string.join(args, ", ") <> ")", after_args)
    }
    _ -> panic as "Syntax Error: Expected a type after ':' or '->'"
  }
}

fn parse_type_args(
  tokens: List(Token),
  acc: List(String),
) -> #(List(String), List(Token)) {
  case tokens {
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)
    _ -> {
      // INTERCEPTOR: If there is a label (e.g., `x: Int`), skip the `x:`!
      let tokens_to_parse = case tokens {
        [lexer.Ident(_label), lexer.Colon, ..rest_after_label] ->
          rest_after_label
        _ -> tokens
      }

      // Parse the actual type (Int)
      let #(t, after_t) = parse_type(tokens_to_parse)

      case after_t {
        [lexer.Comma, ..rest] -> parse_type_args(rest, [t, ..acc])
        [lexer.RParen, ..rest] -> #(list.reverse([t, ..acc]), rest)
        _ -> panic as "Syntax Error: Expected ',' or ')' in type parameters"
      }
    }
  }
}

fn parse_type_definition(
  is_pub: Bool,
  name: String,
  tokens: List(Token),
  acc: List(ast.Statement),
) -> List(ast.Statement) {
  case tokens {
    // Type Alias: pub type Scores = Dict(String, Int)
    [lexer.Eq, ..after_eq] -> {
      let #(type_str, after_type) = parse_type(after_eq)
      let stmt = ast.TypeAliasStmt(is_pub, name, type_str)
      parse_statements(after_type, [stmt, ..acc])
    }

    // Generic type OR Generic Alias: pub type TreasureChest(t) ...
    [lexer.LParen, ..after_lparen] -> {
      let #(params, after_params) = parse_type_args(after_lparen, [])
      let full_name = name <> "(" <> string.join(params, ", ") <> ")"

      case after_params {
        [lexer.LBrace, ..after_brace] -> {
          parse_custom_type(is_pub, full_name, after_brace, acc)
        }
        // Generic Alias: pub type Scores(t) = Dict(String, t)
        [lexer.Eq, ..after_eq] -> {
          let #(type_str, after_type) = parse_type(after_eq)
          let stmt = ast.TypeAliasStmt(is_pub, full_name, type_str)
          parse_statements(after_type, [stmt, ..acc])
        }
        _ ->
          panic as "Syntax Error: Expected '{' or '=' after generic parameters"
      }
    }

    // Non-generic custom type
    [lexer.LBrace, ..after_brace] -> {
      parse_custom_type(is_pub, name, after_brace, acc)
    }

    _ -> panic as "Syntax Error: Expected '(', '{', or '=' after type name"
  }
}

fn parse_custom_type(
  is_pub: Bool,
  name: String,
  tokens: List(Token),
  acc: List(ast.Statement),
) -> List(ast.Statement) {
  let #(variants, after_brace) = parse_type_variants(tokens, [])
  let stmt = ast.CustomTypeStmt(is_pub, name, variants)
  parse_statements(after_brace, [stmt, ..acc])
}

fn parse_type_variants(
  tokens: List(Token),
  acc: List(ast.TypeVariant),
) -> #(List(ast.TypeVariant), List(Token)) {
  case tokens {
    [lexer.RBrace, ..rest] -> #(list.reverse(acc), rest)

    // Variant with fields, e.g. User(name: String, age: Int)
    [lexer.TypeIdent(v_name), lexer.LParen, ..rest] -> {
      let #(fields, after_fields) = parse_type_fields(rest, [])
      parse_type_variants(after_fields, [ast.TypeVariant(v_name, fields), ..acc])
    }

    // Simple Variant without fields, e.g. Active or Offline
    [lexer.TypeIdent(v_name), ..rest] -> {
      parse_type_variants(rest, [ast.TypeVariant(v_name, []), ..acc])
    }

    _ -> panic as "Syntax Error: Expected a variant in custom type definition"
  }
}

fn parse_type_fields(
  tokens: List(Token),
  acc: List(#(String, String)),
) -> #(List(#(String, String)), List(Token)) {
  case tokens {
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)

    // Path A: Labeled field (e.g., `name: String`)
    [lexer.Ident(field_name), lexer.Colon, ..rest] -> {
      let #(type_str, after_type) = parse_type(rest)
      consume_field_separator(after_type, [#(field_name, type_str), ..acc])
    }

    // Path B: Unlabeled field (e.g., `Int` or `Genre`)
    _ -> {
      let #(type_str, after_type) = parse_type(tokens)
      // We pass an empty string "" as the label
      consume_field_separator(after_type, [#("", type_str), ..acc])
    }
  }
}

// Helper to check for commas or the closing parenthesis
fn consume_field_separator(
  tokens: List(Token),
  acc: List(#(String, String)),
) -> #(List(#(String, String)), List(Token)) {
  case tokens {
    [lexer.Comma, ..rest] -> parse_type_fields(rest, acc)
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)
    _ -> panic as "Syntax Error: Expected ',' or ')' in type fields"
  }
}

fn parse_map_pairs(
  tokens: List(Token),
  acc: List(#(ast.Expr, ast.Expr)),
) -> #(List(#(ast.Expr, ast.Expr)), List(Token)) {
  case tokens {
    // Empty map %{} or end of map
    [lexer.RBrace, ..rest] -> #(list.reverse(acc), rest)
    _ -> {
      // 1. Parse the key
      let #(key_expr, after_key) = parse_expression(tokens)

      // 2. Expect the colon instead of fat arrow!
      let assert [lexer.Colon, ..after_colon] = after_key

      // 3. Parse the value
      let #(val_expr, after_val) = parse_expression(after_colon)

      // 4. Look for a comma or the closing brace
      case after_val {
        [lexer.Comma, ..rest] ->
          parse_map_pairs(rest, [#(key_expr, val_expr), ..acc])
        [lexer.RBrace, ..rest] -> #(
          list.reverse([#(key_expr, val_expr), ..acc]),
          rest,
        )
        _ -> panic as "Syntax Error: Expected ',' or '}' in map literal"
      }
    }
  }
}
