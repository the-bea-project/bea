// src/bea/ast.gleam

pub type TypeVariant {
  // name: "User" or "Active"
  // fields: [("name", "String"), ("age", "Int")] 
  // (If there are no fields, it's just an empty list)
  TypeVariant(name: String, fields: List(#(String, String)))
}

pub type Expr {
  IntExpr(Int)
  FloatExpr(Float)
  StringExpr(String)
  IdentExpr(String)
  // Function calls
  CallExpr(name: String, args: List(#(String, Expr)))
  // Binary operations (e.g., left + right)
  BinaryExpr(left: Expr, op: String, right: Expr)
  // A list of expressions, e.g., [1, 2, 3]
  ListExpr(elements: List(Expr))
  // Head tail implementation
  ListConsExpr(head: Expr, tail: Expr)
  // Typed expression, e.g. param: Int
  TypedExpr(expr: Expr, type_name: String)
  UnaryExpr(op: String, expr: Expr)
  // For piping to `echo`
  EchoExpr(Expr)
  CondExpr(clauses: List(CondClause))
  CaseExpr(subject: Expr, clauses: List(CaseClause))
  // Tuple expression `("a", 2)`
  TupleExpr(elements: List(Expr))
  // Indexed tuples `tuple.0`
  TupleIndexExpr(tuple: Expr, index: Int)
  // Anon functions `fn(x) {...}`
  AnonFnExpr(params: List(Expr), body: List(Statement))
  // `?` operator
  TryExpr(Expr)
  // Record update syntax, e.g., Team(team | coach: new_coach)
  RecordUpdateExpr(
    constructor: String,
    base: Expr,
    updates: List(#(String, Expr)),
  )
  // Record field access (e.g., team.coach.name)
  RecordAccessExpr(base: Expr, field: String)
}

pub type Clause {
  Clause(params: List(Expr), body: List(Statement))
}

pub type CondClause {
  CondClause(condition: Expr, body: Expr)
}

pub type CaseClause {
  // patterns: a list of expressions (e.g., [41, 43] for `41 | 43`)
  // guard: an empty list if no guard, or a 1-item list if there is an `if`
  CaseClause(patterns: List(Expr), guard: List(Expr), body: Expr)
}

pub type Statement {
  // A function definition now contains a list of Clauses instead of just one body
  DefStmt(
    is_pub: Bool,
    name: String,
    return_type: String,
    clauses: List(Clause),
  )

  // A return statement evaluates an expression
  ReturnStmt(Expr)

  // Just an expression floating on its own (like `42` or `user_id`)
  ExprStmt(Expr)

  // Assign a value to a variable
  AssignStmt(pattern: Expr, value: Expr)

  // If control flow
  IfStmt(condition: Expr, body: List(Statement), else_body: List(Statement))

  // Import
  ImportStmt(path: String)

  // Custom Types (Structs and Enums)
  CustomTypeStmt(is_pub: Bool, name: String, variants: List(TypeVariant))

  // Module-level constants
  ConstStmt(is_pub: Bool, name: String, value: Expr)
}

// A full Bea program is just a list of top-level statements
pub type Program {
  Program(statements: List(Statement))
}
