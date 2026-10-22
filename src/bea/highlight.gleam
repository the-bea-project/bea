//// Syntax highlighting of Bea and Gleam code for the terminal, in the
//// palette of `bea/style`.

import bea/lexer.{type Token, Token}
import bea/span.{type Span, Span}
import bea/style.{
  dark_grey, deep_purple, lavender, mauve, orchid, periwinkle, plum, purple, sgr,
}
import gleam/int
import gleam/list
import gleam/string

pub type Language {
  Bea
  Gleam
}

/// Highlight source code. Anything the lexer can't make sense of is left
/// as it is.
pub fn code(source: String, language: Language) -> String {
  let lexed = lexer.lex(source)
  let paints =
    list.flatten([
      paint_tokens(lexed.tokens, language),
      list.map(lexed.comments, fn(c) { #(c.span, "3;" <> dark_grey) }),
    ])
    |> list.sort(fn(a, b) { int.compare({ a.0 }.start, { b.0 }.start) })
  render(source, paints)
}

fn render(source: String, paints: List(#(Span, String))) -> String {
  let size = string.byte_size(source)
  let #(out, at) =
    list.fold(paints, #([], 0), fn(acc, p) {
      let #(out, at) = acc
      let #(s, codes) = p
      case s.start >= at && s.end <= size && s.end > s.start {
        False -> acc
        True -> #(
          [
            sgr(codes, span.text(source, s)),
            span.text(source, Span(at, s.start)),
            ..out
          ],
          s.end,
        )
      }
    })
  [span.text(source, Span(at, size)), ..out] |> list.reverse |> string.concat
}

fn paint_tokens(
  tokens: List(Token),
  language: Language,
) -> List(#(Span, String)) {
  case tokens {
    [] -> []
    [Token(lexer.Name(_), s, _), Token(lexer.LParen, p, _), ..]
      if s.end == p.start
    -> [#(s, orchid), ..paint_tokens(list.drop(tokens, 1), language)]
    [Token(lexer.Str(parts), s, _), ..rest] ->
      list.append(
        string_paints(s, parts, language),
        paint_tokens(rest, language),
      )
    [Token(kind, s, _), ..rest] ->
      case token_style(kind, language) {
        "" -> paint_tokens(rest, language)
        codes -> [#(s, codes), ..paint_tokens(rest, language)]
      }
  }
}

/// A string is mauve, its `#{...}` interpolations highlighted as code.
fn string_paints(
  s: Span,
  parts: List(lexer.StrPart),
  language: Language,
) -> List(#(Span, String)) {
  let #(paints, at) =
    list.fold(parts, #([], s.start), fn(acc, part) {
      let #(paints, at) = acc
      case part {
        lexer.StrText(..) -> acc
        lexer.StrCode(tokens, _) ->
          case tokens, list.last(tokens) {
            [first, ..], Ok(last) -> #(
              list.flatten([
                paints,
                [#(Span(at, first.span.start), mauve)],
                paint_tokens(tokens, language),
              ]),
              last.span.end,
            )
            _, _ -> acc
          }
      }
    })
  list.append(paints, [#(Span(at, s.end), mauve)])
}

fn token_style(kind: lexer.Kind, language: Language) -> String {
  case kind {
    lexer.Import
    | lexer.As
    | lexer.Pub
    | lexer.Def
    | lexer.Fn
    | lexer.Type
    | lexer.Opaque
    | lexer.Const
    | lexer.If
    | lexer.Else
    | lexer.Cond
    | lexer.Case
    | lexer.Return
    | lexer.Use
    | lexer.Echo
    | lexer.Todo
    | lexer.Panic
    | lexer.Assert
    | lexer.And
    | lexer.Or
    | lexer.Not -> "1;" <> purple
    lexer.Name("let") if language == Gleam -> "1;" <> purple
    lexer.UpName(_) -> lavender
    lexer.RawStr(_) -> mauve
    lexer.Int(_) | lexer.Float(_) -> periwinkle
    lexer.Question -> "1;" <> orchid
    lexer.At -> deep_purple
    lexer.PipeRight
    | lexer.Arrow
    | lexer.LArrow
    | lexer.Eq
    | lexer.EqEq
    | lexer.NotEq
    | lexer.Less
    | lexer.LessEq
    | lexer.Greater
    | lexer.GreaterEq
    | lexer.LessDot
    | lexer.LessEqDot
    | lexer.GreaterDot
    | lexer.GreaterEqDot
    | lexer.Plus
    | lexer.Minus
    | lexer.Star
    | lexer.Slash
    | lexer.Percent
    | lexer.PlusDot
    | lexer.MinusDot
    | lexer.StarDot
    | lexer.SlashDot
    | lexer.Concat
    | lexer.Bang
    | lexer.AmpAmp
    | lexer.PipePipe
    | lexer.Pipe -> plum
    _ -> ""
  }
}

pub fn bea(source: String) -> String {
  code(source, Bea)
}

pub fn gleam(source: String) -> String {
  code(source, Gleam)
}
