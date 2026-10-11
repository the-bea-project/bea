// test/lexer_test.gleam

import bea/lexer.{
  Def, Eof, Ident, IntLit, LBrace, LParen, RBrace, RParen, Return,
}
import gleeunit/should

pub fn lexer_basic_function_test() {
  let source =
    "
    def process(user_id) {
      return 42
    }
  "

  lexer.tokenize(source)
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
