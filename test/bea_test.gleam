import bea/lexer.{
  Def, Eof, Ident, IntLit, LBrace, LParen, RBrace, RParen, Return, tokenize,
}
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn lexer_basic_function_test() {
  let source =
    "
    def process(user_id) {
      return 42
    }
  "

  // Run the lexer
  let tokens = tokenize(source)

  // Assert that it produces the exact tokens we expect
  tokens
  |> should.equal([
    Def,
    Ident("process"),
    LParen,
    Ident("user_id"),
    RParen,
    LBrace,
    Return,
    IntLit(42),
    RBrace,
    Eof,
  ])
}
