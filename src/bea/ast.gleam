// src/bea/ast.gleam

pub type Expr {
  IntExpr(Int)
  StringExpr(String)
  IdentExpr(String)
  // Function calls
  CallExpr(name: String, args: List(Expr))
  // Binary operations (e.g., left + right)
  BinaryExpr(left: Expr, op: String, right: Expr)
  // A list of expressions, e.g., [1, 2, 3]
  ListExpr(elements: List(Expr))
}

pub type Statement {
  // A function definition needs a name, parameters, and a body
  DefStmt(name: String, params: List(String), body: List(Statement))

  // A return statement evaluates an expression
  ReturnStmt(Expr)

  // Just an expression floating on its own (like `42` or `user_id`)
  ExprStmt(Expr)

  // Assign a value to a variable
  AssignStmt(name: String, value: Expr)

  // If control flow
  IfStmt(condition: Expr, body: List(Statement), else_body: List(Statement))
}

// A full Bea program is just a list of top-level statements
pub type Program {
  Program(statements: List(Statement))
}
