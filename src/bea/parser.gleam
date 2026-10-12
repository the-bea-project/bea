// src/bea/parser.gleam
// src/bea/parser.gleam

import bea/ast
import bea/lexer.{type Token}
import gleam/list

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

    // (The old duplicate block was safely removed from here!)
    [lexer.Echo, ..rest] -> {
      let #(expr, after_expr) = parse_expression(rest)
      parse_statements(after_expr, [ast.Echo(expr), ..acc])
    }

    [lexer.Import, ..rest] -> {
      let #(path, after_path) = parse_import_path(rest, "")
      parse_statements(after_path, [ast.ImportStmt(path), ..acc])
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
      // 1. Parse the parameter name
      let #(expr, after_expr) = parse_expression(tokens)

      // 2. Intercept type annotations (e.g., `: Int`)
      let #(final_expr, after_type) = case after_expr {
        [lexer.Colon, lexer.TypeIdent(type_name), ..rest2] -> #(
          ast.TypedExpr(expr, type_name),
          rest2,
        )
        _ -> #(expr, after_expr)
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
    // Match all 4 arguments for both DefStmts
    [
      ast.DefStmt(p1, name1, ret1, clauses1),
      ast.DefStmt(_p2, name2, _ret2, clauses2),
      ..rest
    ]
      if name1 == name2
    -> {
      collapse_clauses([
        ast.DefStmt(p1, name1, ret1, list.append(clauses1, clauses2)),
        ..rest
      ])
    }
    [stmt, ..rest] -> [stmt, ..collapse_clauses(rest)]
  }
}

fn parse_primary(tokens: List(Token)) -> #(ast.Expr, List(Token)) {
  case tokens {
    [lexer.IntLit(val), ..rest] -> #(ast.IntExpr(val), rest)
    [lexer.StringLit(val), ..rest] -> #(ast.StringExpr(val), rest)

    [lexer.Not, ..rest] -> {
      let #(inner_expr, after_inner) = parse_primary(rest)
      #(ast.UnaryExpr("not", inner_expr), after_inner)
    }

    // Standard function calls (e.g., calculate(10))
    [lexer.Ident(name), lexer.LParen, ..rest] -> {
      let #(args, after_args) = parse_args(rest, [])
      #(ast.CallExpr(name, args), after_args)
    }

    // Constructor calls (e.g., Ok(42) or User("Alice"))
    [lexer.TypeIdent(name), lexer.LParen, ..rest] -> {
      let #(args, after_args) = parse_args(rest, [])
      #(ast.CallExpr(name, args), after_args)
    }

    // Intercept Lists
    [lexer.LBracket, ..rest] -> {
      let #(elements, after_elements) = parse_list_elements(rest, [])
      #(ast.ListExpr(elements), after_elements)
    }

    // For module calls like `io.println()`
    [lexer.Ident(module), lexer.Dot, lexer.Ident(name), lexer.LParen, ..rest] -> {
      let #(args, after_args) = parse_args(rest, [])
      // Combine them into a single CallExpr string for the backend
      #(ast.CallExpr(module <> "." <> name, args), after_args)
    }

    // Standalone variables
    [lexer.Ident(name), ..rest] -> #(ast.IdentExpr(name), rest)

    // Standalone constructors (e.g., True, False)
    [lexer.TypeIdent(name), ..rest] -> #(ast.IdentExpr(name), rest)

    _ -> panic as "Syntax Error: Expected an expression"
  }
}

fn parse_expression(tokens: List(Token)) -> #(ast.Expr, List(Token)) {
  let #(left, after_left) = parse_primary(tokens)

  case after_left {
    [lexer.Plus, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "+", right), after_right)
    }
    [lexer.Minus, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "-", right), after_right)
    }
    [lexer.Star, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "*", right), after_right)
    }
    [lexer.Slash, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "/", right), after_right)
    }
    [lexer.Greater, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, ">", right), after_right)
    }
    [lexer.EqEq, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "==", right), after_right)
    }
    [lexer.BangEq, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "!=", right), after_right)
    }
    [lexer.Concat, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "<>", right), after_right)
    }
    [lexer.And, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "and", right), after_right)
    }
    [lexer.Or, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "or", right), after_right)
    }

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

    // Variable Assignment (e.g., status = "active")
    [lexer.Ident(name), lexer.Eq, ..rest] -> {
      let #(expr, after_expr) = parse_expression(rest)
      parse_block(after_expr, [ast.AssignStmt(name, expr), ..acc])
    }

    // If / Else statements
    [lexer.If, ..rest] -> {
      let #(if_stmt, after_if) = parse_if(rest)
      parse_block(after_if, [if_stmt, ..acc])
    }

    [lexer.Echo, ..rest] -> {
      let #(expr, after_expr) = parse_expression(rest)
      parse_block(after_expr, [ast.Echo(expr), ..acc])
    }

    // Catch-all: Standalone expression
    _ -> {
      let #(expr, after_expr) = parse_expression(tokens)
      parse_block(after_expr, [ast.ExprStmt(expr), ..acc])
    }
  }
}

fn parse_args(
  tokens: List(Token),
  acc: List(ast.Expr),
) -> #(List(ast.Expr), List(Token)) {
  case tokens {
    // Hit the closing parenthesis
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)

    // Otherwise, parse the next expression
    _ -> {
      let #(expr, after_expr) = parse_expression(tokens)

      case after_expr {
        // If there's a comma, consume it and keep parsing arguments
        [lexer.Comma, ..rest] -> parse_args(rest, [expr, ..acc])
        // If there's a closing parenthesis, consume it and finish
        [lexer.RParen, ..rest] -> #(list.reverse([expr, ..acc]), rest)
        _ -> panic as "Syntax Error: Expected ',' or ')' in function arguments"
      }
    }
  }
}

fn parse_list_elements(
  tokens: List(Token),
  acc: List(ast.Expr),
) -> #(List(ast.Expr), List(Token)) {
  case tokens {
    // Empty list or reached the end
    [lexer.RBracket, ..rest] -> #(list.reverse(acc), rest)

    // Otherwise, parse an expression
    _ -> {
      let #(expr, after_expr) = parse_expression(tokens)

      case after_expr {
        [lexer.Comma, ..rest] -> parse_list_elements(rest, [expr, ..acc])
        [lexer.RBracket, ..rest] -> #(list.reverse([expr, ..acc]), rest)
        _ -> panic as "Syntax Error: Expected ',' or ']' in list"
      }
    }
  }
}

fn parse_if(tokens: List(Token)) -> #(ast.Statement, List(Token)) {
  // 1. Parse condition
  let #(condition, after_cond) = parse_expression(tokens)

  // 2. Expect '{' and parse body
  let assert [lexer.LBrace, ..after_lbrace] = after_cond
  let #(body, after_body) = parse_block(after_lbrace, [])

  // 3. Check what comes after the block
  case after_body {
    // Handle 'else if' by recursively calling parse_if
    [lexer.Else, lexer.If, ..after_elif] -> {
      let #(elif_stmt, after_all) = parse_if(after_elif)
      // Wrap the else-if statement inside a list for the else_body
      #(ast.IfStmt(condition, body, [elif_stmt]), after_all)
    }

    // Handle standard 'else {'
    [lexer.Else, lexer.LBrace, ..after_else_lbrace] -> {
      let #(else_body, after_else) = parse_block(after_else_lbrace, [])
      #(ast.IfStmt(condition, body, else_body), after_else)
    }

    // No else block
    _ -> #(ast.IfStmt(condition, body, []), after_body)
  }
}

fn parse_import_path(
  tokens: List(Token),
  acc: String,
) -> #(String, List(Token)) {
  case tokens {
    [lexer.Ident(name), ..rest] -> parse_import_path(rest, acc <> name)
    [lexer.Slash, ..rest] -> parse_import_path(rest, acc <> "/")
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
    [lexer.Arrow, lexer.TypeIdent(t), ..rest2] -> #(t, rest2)
    _ -> #("", after_params)
  }

  case after_ret {
    [lexer.LBrace, ..after_brace] -> {
      let #(body, after_block) = parse_block(after_brace, [])
      let clause = ast.Clause(params: params, body: body)
      // Pass the return_type here
      let def_stmt =
        ast.DefStmt(
          is_pub: is_pub,
          name: name,
          return_type: return_type,
          clauses: [clause],
        )
      parse_statements(after_block, [def_stmt, ..acc])
    }
    _ ->
      panic as "Syntax Error: Expected '{' after function parameters or return type"
  }
}
