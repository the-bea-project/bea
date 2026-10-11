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
    [lexer.Eof] | [] -> acc

    // Match up to the opening parenthesis
    [lexer.Def, lexer.Ident(name), lexer.LParen, ..rest] -> {
      // 1. Dynamically parse the parameter list
      let #(params, after_params) = parse_params(rest, [])

      // 2. Expect the opening brace `{`, then parse the block
      case after_params {
        [lexer.LBrace, ..after_brace] -> {
          let #(body, after_block) = parse_block(after_brace, [])

          let def_stmt = ast.DefStmt(name: name, params: params, body: body)
          parse_statements(after_block, [def_stmt, ..acc])
        }
        _ -> panic as "Syntax Error: Expected '{' after function parameters"
      }
    }

    [_, ..rest] -> parse_statements(rest, acc)
  }
}

fn parse_primary(tokens: List(Token)) -> #(ast.Expr, List(Token)) {
  case tokens {
    [lexer.IntLit(val), ..rest] -> #(ast.IntExpr(val), rest)
    [lexer.StringLit(val), ..rest] -> #(ast.StringExpr(val), rest)

    [lexer.Ident(name), lexer.LParen, ..rest] -> {
      let #(args, after_args) = parse_args(rest, [])
      #(ast.CallExpr(name, args), after_args)
    }

    // Intercept Lists
    [lexer.LBracket, ..rest] -> {
      let #(elements, after_elements) = parse_list_elements(rest, [])
      #(ast.ListExpr(elements), after_elements)
    }

    [lexer.Ident(name), ..rest] -> #(ast.IdentExpr(name), rest)

    _ -> panic as "Syntax Error: Expected an expression"
  }
}

fn parse_expression(tokens: List(Token)) -> #(ast.Expr, List(Token)) {
  // 1. Always parse the left side first (a number, variable, etc.)
  let #(left, after_left) = parse_primary(tokens)

  // 2. Check if an operator immediately follows it
  case after_left {
    [lexer.Plus, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "+", right), after_right)
    }
    [lexer.Minus, ..rest] -> {
      let #(right, after_right) = parse_expression(rest)
      #(ast.BinaryExpr(left, "-", right), after_right)
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

    // You can add Star (*) and Slash (/) here easily later!
    // 3. If no operator is found, just return the primary expression
    _ -> #(left, after_left)
  }
}

fn parse_params(
  tokens: List(Token),
  acc: List(String),
) -> #(List(String), List(Token)) {
  case tokens {
    // 1. Base case: We hit the closing parenthesis
    [lexer.RParen, ..rest] -> #(list.reverse(acc), rest)

    // 2. Found a parameter followed by a comma (e.g., `a,`)
    [lexer.Ident(param), lexer.Comma, ..rest] ->
      parse_params(rest, [param, ..acc])

    // 3. Found the last parameter followed by the closing parenthesis (e.g., `a)`)
    [lexer.Ident(param), lexer.RParen, ..rest] -> #(
      list.reverse([param, ..acc]),
      rest,
    )

    _ -> panic as "Syntax Error: Expected parameter name or ')'"
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
    // NEW: Handle 'else if' by recursively calling parse_if
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
