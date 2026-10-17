import bea/lexer.{Def, Eof, Int, LBrace, LParen, Name, RBrace, RParen, Return}
import bea/span.{Span}
import gleam/list

pub fn basic_function_test() {
  let source = "def process(user_id) {\n  return 42\n}"
  assert lexer.tokenize(source)
    == [
      Def,
      Name("process"),
      LParen,
      Name("user_id"),
      RParen,
      LBrace,
      Return,
      Int("42"),
      RBrace,
      Eof,
    ]
}

pub fn spans_are_byte_offsets_test() {
  let lexed = lexer.lex("x = \"é\" + y")
  let spans = list.map(lexed.tokens, fn(t) { t.span })
  // `é` is two bytes, so `+` starts at byte 9.
  assert spans
    == [
      Span(0, 1),
      Span(2, 3),
      Span(4, 8),
      Span(9, 10),
      Span(11, 12),
      Span(12, 12),
    ]
}

pub fn newline_flags_test() {
  let lexed = lexer.lex("a\nb c")
  assert list.map(lexed.tokens, fn(t) { t.nl_before })
    == [True, True, False, False]
}

pub fn numbers_test() {
  assert lexer.tokenize("0xFF 0b1010 0o17 1_000 1.5 2.0e-3 t.0.1")
    == [
      Int("0xFF"),
      Int("0b1010"),
      Int("0o17"),
      Int("1_000"),
      lexer.Float("1.5"),
      lexer.Float("2.0e-3"),
      Name("t"),
      lexer.Dot,
      Int("0"),
      lexer.Dot,
      Int("1"),
      Eof,
    ]
}

pub fn interpolation_test() {
  let lexed = lexer.lex("\"a #{f(\"}\")} b\"")
  let assert [lexer.Token(lexer.Str(parts), _, _), _] = lexed.tokens
  let assert [
    lexer.StrText("a ", _),
    lexer.StrCode(code, _),
    lexer.StrText(" b", _),
  ] = parts
  assert list.map(code, fn(t) { t.kind })
    == [Name("f"), LParen, lexer.Str([lexer.StrText("}", Span(8, 9))]), RParen]
}

pub fn escaped_interpolation_is_text_test() {
  let lexed = lexer.lex("\"\\#{x}\"")
  let assert [lexer.Token(lexer.Str([lexer.StrText(raw, _)]), _, _), _] =
    lexed.tokens
  assert lexer.to_gleam_string_content(raw) == "#{x}"
}

pub fn errors_test() {
  let lexed = lexer.lex("x = 'a' + \"\\q\" + \"open")
  assert list.map(lexed.errors, fn(e) { e.title })
    == [
      "Single quoted string",
      "Unknown escape sequence",
      "Unterminated string",
    ]
}

pub fn comments_are_kept_test() {
  let lexed = lexer.lex("//// module\n/// doc\n// plain\nx")
  assert list.map(lexed.comments, fn(c) { #(c.kind, c.text) })
    == [
      #(lexer.ModuleDoc, " module"),
      #(lexer.Doc, " doc"),
      #(lexer.Regular, " plain"),
    ]
}
