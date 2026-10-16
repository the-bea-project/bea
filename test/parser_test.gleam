// test/parser_test.gleam

import bea/ast
import bea/lexer
import bea/parser
import gleeunit/should

pub fn parser_basic_function_test() {
  let source =
    "
    def process(user_id, status) {
      status = \"active\"
      notify(user_id, status)
      return 40 + 2
    }
  "

  let tokens = lexer.tokenize(source)
  let tree = parser.parse(tokens)

  let expected_body = [
    ast.AssignStmt(ast.IdentExpr("status"), ast.StringExpr("active")),
    ast.ExprStmt(
      ast.CallExpr("notify", [
        #("", ast.IdentExpr("user_id")),
        #("", ast.IdentExpr("status")),
      ]),
    ),
    ast.ReturnStmt(ast.BinaryExpr(ast.IntExpr(40), "+", ast.IntExpr(2))),
  ]

  let expected_clause =
    ast.Clause(
      [ast.IdentExpr("user_id"), ast.IdentExpr("status")],
      [],
      expected_body,
    )

  let expected_def = ast.DefStmt(False, "process", "", [expected_clause])

  tree
  |> should.equal(ast.Program([expected_def]))
}

pub fn parser_if_statement_test() {
  let source =
    "
    def check_status(status) {
      if status {
        return \"active\"
      } else {
        return \"inactive\"
      }
    }
  "

  let tokens = lexer.tokenize(source)
  let tree = parser.parse(tokens)

  let if_body = [ast.ReturnStmt(ast.StringExpr("active"))]
  let else_body = [ast.ReturnStmt(ast.StringExpr("inactive"))]

  // FIX: Wrap the new IfExpr inside an ExprStmt
  let expected_body = [
    ast.ExprStmt(ast.IfExpr(ast.IdentExpr("status"), if_body, else_body)),
  ]

  let expected_clause = ast.Clause([ast.IdentExpr("status")], [], expected_body)

  let expected_def = ast.DefStmt(False, "check_status", "", [expected_clause])

  tree
  |> should.equal(ast.Program([expected_def]))
}
