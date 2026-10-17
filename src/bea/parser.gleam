//// The Bea parser.
////
//// A hand written recursive descent parser with precedence climbing for
//// binary operators (using Gleam's precedence table). Parse errors never
//// panic: each failing top level item produces a diagnostic and the parser
//// resynchronises at the next item, so editors get every error at once.
////
//// Bea has no statement terminators, so a few tokens are newline sensitive:
//// a `(` only starts a call when it is on the same line as the callee, and a
//// `-` at the start of a line starts a new expression rather than continuing
//// a subtraction.

import bea/ast.{
  type Arg, type Attribute, type BinOp, type CaseClause, type CondClause,
  type Expr, type Field, type FnParam, type Item, type Pattern, type PatternArg,
  type Statement, type Type, type Unqualified, type UsePattern, type Variant,
}
import bea/diagnostic.{type Diagnostic}
import bea/lexer.{type Comment, type Kind, type Token, Token}
import bea/span.{type Span, Span}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Tokens =
  List(Token)

type Parsed(a) =
  Result(#(a, Tokens), Diagnostic)

pub type ParseResult {
  ParseResult(
    module: ast.Module,
    comments: List(Comment),
    errors: List(Diagnostic),
  )
}

pub fn parse_module(source: String) -> ParseResult {
  let lexed = lexer.lex(source)
  let #(items, errors) = items(lexed.tokens, [], [])
  let items =
    items
    |> attach_docs(lexed.comments, 0, [])
    |> collapse_clauses
  let module_doc =
    lexed.comments
    |> list.filter(fn(c) { c.kind == lexer.ModuleDoc })
    |> list.map(fn(c) { c.text })
  ParseResult(
    module: ast.Module(items, module_doc),
    comments: lexed.comments,
    errors: list.flatten([lexed.errors, reserved_words(lexed.tokens), errors]),
  )
}

// --- Token helpers -----------------------------------------------------------

fn peek(ts: Tokens) -> Token {
  case ts {
    [t, ..] -> t
    [] -> Token(lexer.Eof, span.empty, True)
  }
}

fn peek_kind(ts: Tokens) -> Kind {
  peek(ts).kind
}

fn advance(ts: Tokens) -> Tokens {
  case ts {
    [Token(lexer.Eof, _, _)] -> ts
    [_, ..rest] -> rest
    [] -> []
  }
}

fn unexpected(t: Token, expected: String) -> Diagnostic {
  let what = case lexer.describe(t.kind) {
    "the " <> rest -> rest
    other -> other
  }
  diagnostic.error(
    "Unexpected " <> what,
    t.span,
    "I was expecting " <> expected,
  )
}

fn expect(ts: Tokens, kind: Kind, expected: String) -> Parsed(Token) {
  let t = peek(ts)
  case t.kind == kind {
    True -> Ok(#(t, advance(ts)))
    False -> Error(unexpected(t, expected))
  }
}

fn expect_name(ts: Tokens, expected: String) -> Parsed(#(String, Span)) {
  case ts {
    [Token(lexer.Name(n), s, _), ..rest] -> Ok(#(#(n, s), rest))
    _ -> Error(unexpected(peek(ts), expected))
  }
}

fn expect_upname(ts: Tokens, expected: String) -> Parsed(#(String, Span)) {
  case ts {
    [Token(lexer.UpName(n), s, _), ..rest] -> Ok(#(#(n, s), rest))
    _ -> Error(unexpected(peek(ts), expected))
  }
}

/// The span from `start` to the end of the last consumed token. We compute
/// it from the first token *not* consumed is not possible, so callers pass
/// the end explicitly.
fn sp(start: Span, end: Span) -> Span {
  Span(start.start, end.end)
}

/// Parse a comma separated sequence until `close`, allowing a trailing comma.
fn sequence(
  ts: Tokens,
  close: Kind,
  close_name: String,
  element: fn(Tokens) -> Parsed(a),
  acc: List(a),
) -> Parsed(#(List(a), Token)) {
  case ts {
    [Token(k, _, _) as t, ..rest] if k == close ->
      Ok(#(#(list.reverse(acc), t), rest))
    _ -> {
      use #(el, ts) <- result.try(element(ts))
      case ts {
        [Token(lexer.Comma, _, _), ..rest] ->
          sequence(rest, close, close_name, element, [el, ..acc])
        [Token(k, _, _) as t, ..rest] if k == close ->
          Ok(#(#(list.reverse([el, ..acc]), t), rest))
        _ -> Error(unexpected(peek(ts), "`,` or " <> close_name))
      }
    }
  }
}

// --- Items ---------------------------------------------------------------------

fn items(
  ts: Tokens,
  acc: List(Item),
  errors: List(Diagnostic),
) -> #(List(Item), List(Diagnostic)) {
  case peek_kind(ts) {
    lexer.Eof -> #(list.reverse(acc), list.reverse(errors))
    _ ->
      case item(ts) {
        Ok(#(it, rest)) ->
          case peek(rest) {
            Token(lexer.Eof, _, _) -> items(rest, [it, ..acc], errors)
            Token(_, _, True) -> items(rest, [it, ..acc], errors)
            t -> {
              let e = unexpected(t, "a new line before the next definition")
              items(recover(advance(rest)), [it, ..acc], [e, ..errors])
            }
          }
        Error(e) -> items(recover(advance(ts)), acc, [e, ..errors])
      }
  }
}

/// Skip ahead to something that looks like the start of a top level item.
fn recover(ts: Tokens) -> Tokens {
  case ts {
    [] -> []
    [Token(lexer.Eof, _, _), ..] -> ts
    [Token(k, _, True), ..] ->
      case k {
        lexer.Pub
        | lexer.Def
        | lexer.Type
        | lexer.Opaque
        | lexer.Const
        | lexer.Import
        | lexer.At -> ts
        _ -> recover(advance(ts))
      }
    _ -> recover(advance(ts))
  }
}

fn item(ts: Tokens) -> Parsed(Item) {
  let start = peek(ts).span
  use #(attrs, ts) <- result.try(attributes(ts, []))
  let #(publicity, ts) = case ts {
    [Token(lexer.Pub, _, _), ..rest] -> #(ast.Public, rest)
    _ -> #(ast.Private, ts)
  }
  case ts {
    [Token(lexer.Import, _, _), ..rest] -> {
      case attrs, publicity {
        [], ast.Private -> import_(start, rest)
        _, _ ->
          Error(diagnostic.error(
            "Invalid import",
            start,
            "imports cannot be public or have attributes",
          ))
      }
    }
    [Token(lexer.Def, _, _), ..rest] -> def(start, attrs, publicity, rest)
    [Token(lexer.Type, _, _), ..rest] ->
      type_definition(start, attrs, publicity, False, rest)
    [Token(lexer.Opaque, _, _), Token(lexer.Type, _, _), ..rest] ->
      type_definition(start, attrs, publicity, True, rest)
    [Token(lexer.Const, _, _), ..rest] -> const_(start, attrs, publicity, rest)
    [Token(lexer.Name("fn"), s, _), ..] | [Token(lexer.Fn, s, _), ..] ->
      Error(
        diagnostic.error(
          "Unexpected `fn`",
          s,
          "named functions are defined with `def`",
        )
        |> diagnostic.with_hint("Write `def name(...) { ... }` instead."),
      )
    [Token(lexer.Name("let"), s, _), ..] ->
      Error(
        diagnostic.error("Unexpected `let`", s, "Bea has no `let` keyword")
        |> diagnostic.with_hint("Assign with `name = value` inside a function."),
      )
    _ ->
      Error(unexpected(
        peek(ts),
        "a definition: `def`, `type`, `const` or `import`",
      ))
  }
}

fn attributes(ts: Tokens, acc: List(Attribute)) -> Parsed(List(Attribute)) {
  case ts {
    [Token(lexer.At, start, _), ..rest] -> {
      use #(#(name, name_span), rest) <- result.try(expect_name(
        rest,
        "an attribute name",
      ))
      case rest {
        [Token(lexer.LParen, _, False), ..rest] -> {
          use #(#(args, close), rest) <- result.try(
            sequence(rest, lexer.RParen, "`)`", attribute_arg, []),
          )
          let attr = ast.Attribute(sp(start, close.span), name, args)
          attributes(rest, [attr, ..acc])
        }
        _ ->
          attributes(rest, [
            ast.Attribute(sp(start, name_span), name, []),
            ..acc
          ])
      }
    }
    _ -> Ok(#(list.reverse(acc), ts))
  }
}

fn attribute_arg(ts: Tokens) -> Parsed(ast.AttributeArg) {
  case ts {
    [Token(lexer.Name(n), _, _), ..rest] -> Ok(#(ast.AttrName(n), rest))
    [Token(lexer.Str([lexer.StrText(raw, _)]), _, _), ..rest] ->
      Ok(#(ast.AttrString(raw), rest))
    [Token(lexer.Str([]), _, _), ..rest] -> Ok(#(ast.AttrString(""), rest))
    _ -> Error(unexpected(peek(ts), "a name or a plain string"))
  }
}

fn import_(start: Span, ts: Tokens) -> Parsed(Item) {
  use #(#(first, first_span), ts) <- result.try(module_segment(ts))
  use #(#(module, module_span), ts) <- result.try(module_path(
    ts,
    first,
    first_span,
  ))
  use #(#(unqualified, end), ts) <- result.try(case ts {
    [Token(lexer.Dot, _, False), Token(lexer.LBrace, _, _), ..rest] -> {
      use #(#(uqs, close), rest) <- result.try(
        sequence(rest, lexer.RBrace, "`}`", unqualified, []),
      )
      Ok(#(#(uqs, close.span), rest))
    }
    _ -> Ok(#(#([], module_span), ts))
  })
  use #(#(alias, end), ts) <- result.try(case ts {
    [Token(lexer.As, _, False), ..rest] -> {
      case rest {
        [Token(lexer.Name(n), s, _), ..rest] -> Ok(#(#(Some(#(n, s)), s), rest))
        [Token(lexer.Underscore, s, _), ..rest] ->
          Ok(#(#(Some(#("_", s)), s), rest))
        _ -> Error(unexpected(peek(rest), "a module alias"))
      }
    }
    _ -> Ok(#(#(None, end), ts))
  })
  Ok(#(ast.Import(sp(start, end), module, module_span, alias, unqualified), ts))
}

fn module_segment(ts: Tokens) -> Parsed(#(String, Span)) {
  case ts {
    [Token(kind, s, _), ..rest] ->
      case kind {
        lexer.Name(n) -> Ok(#(#(n, s), rest))
        // Allow keywords as path segments, e.g. `import my/type`.
        lexer.Type -> Ok(#(#("type", s), rest))
        lexer.Use -> Ok(#(#("use", s), rest))
        lexer.Echo -> Ok(#(#("echo", s), rest))
        lexer.Case -> Ok(#(#("case", s), rest))
        _ -> Error(unexpected(peek(ts), "a module name"))
      }
    [] -> Error(unexpected(peek(ts), "a module name"))
  }
}

fn module_path(
  ts: Tokens,
  acc: String,
  acc_span: Span,
) -> Parsed(#(String, Span)) {
  case ts {
    [Token(lexer.Slash, _, False), ..rest] -> {
      use #(#(seg, seg_span), rest) <- result.try(module_segment(rest))
      module_path(rest, acc <> "/" <> seg, sp(acc_span, seg_span))
    }
    _ -> Ok(#(#(acc, acc_span), ts))
  }
}

fn unqualified(ts: Tokens) -> Parsed(Unqualified) {
  let start = peek(ts).span
  let #(is_type, ts) = case ts {
    [Token(lexer.Type, _, _), ..rest] -> #(True, rest)
    _ -> #(False, ts)
  }
  use #(#(name, name_span), ts) <- result.try(case ts {
    [Token(lexer.UpName(n), s, _), ..rest] -> Ok(#(#(n, s), rest))
    [Token(kind, s, _), ..rest] ->
      case keyword_name(kind) {
        Some(n) -> Ok(#(#(n, s), rest))
        None -> Error(unexpected(peek(ts), "a name to import"))
      }
    _ -> Error(unexpected(peek(ts), "a name to import"))
  })
  case ts {
    [Token(lexer.As, _, _), Token(lexer.Name(a), s, _), ..rest]
    | [Token(lexer.As, _, _), Token(lexer.UpName(a), s, _), ..rest] ->
      Ok(#(ast.Unqualified(sp(start, s), is_type, name, Some(a)), rest))
    _ -> Ok(#(ast.Unqualified(sp(start, name_span), is_type, name, None), ts))
  }
}

fn const_(
  start: Span,
  attrs: List(Attribute),
  publicity: ast.Publicity,
  ts: Tokens,
) -> Parsed(Item) {
  use #(#(name, name_span), ts) <- result.try(expect_name(ts, "a constant name"))
  use #(annotation, ts) <- result.try(optional_annotation(ts))
  use #(_, ts) <- result.try(expect(ts, lexer.Eq, "`=`"))
  use #(value, ts) <- result.try(expression(ts))
  Ok(#(
    ast.Const(
      sp(start, value.span),
      [],
      attrs,
      publicity,
      name,
      name_span,
      annotation,
      value,
    ),
    ts,
  ))
}

fn optional_annotation(ts: Tokens) -> Parsed(Option(Type)) {
  case ts {
    [Token(lexer.Colon, _, _), ..rest] -> {
      use #(t, rest) <- result.try(type_(rest))
      Ok(#(Some(t), rest))
    }
    _ -> Ok(#(None, ts))
  }
}

// --- Functions -----------------------------------------------------------------

fn def(
  start: Span,
  attrs: List(Attribute),
  publicity: ast.Publicity,
  ts: Tokens,
) -> Parsed(Item) {
  use #(#(name, name_span), ts) <- result.try(expect_name(ts, "a function name"))
  use #(_, ts) <- result.try(expect(ts, lexer.LParen, "`(`"))
  use #(#(params, close), ts) <- result.try(
    sequence(ts, lexer.RParen, "`)`", param, []),
  )
  use #(return_type, ts) <- result.try(case ts {
    [Token(lexer.Arrow, _, _), ..rest] -> {
      use #(t, rest) <- result.try(type_(rest))
      Ok(#(Some(t), rest))
    }
    _ -> Ok(#(None, ts))
  })
  use #(guard, ts) <- result.try(case ts {
    [Token(lexer.If, _, _), ..rest] -> {
      use #(g, rest) <- result.try(expression(rest))
      Ok(#(Some(g), rest))
    }
    _ -> Ok(#(None, ts))
  })
  let header_end = case guard, return_type {
    Some(g), _ -> g.span
    None, Some(t) -> t.span
    None, None -> close.span
  }
  use #(#(body, end), ts) <- result.try(case ts {
    [Token(lexer.LBrace, _, _), ..rest] -> {
      use #(#(stmts, close), rest) <- result.try(block_body(rest))
      Ok(#(#(Some(stmts), close), rest))
    }
    _ ->
      case guard {
        Some(_) -> Error(unexpected(peek(ts), "`{` to start the function body"))
        None -> Ok(#(#(None, header_end), ts))
      }
  })
  let clause =
    ast.Clause(
      sp(start, end),
      [],
      attrs,
      publicity,
      name_span,
      params,
      return_type,
      guard,
      body,
    )
  Ok(#(ast.Function(sp(start, end), name, name_span, [clause]), ts))
}

fn param(ts: Tokens) -> Parsed(ast.Param) {
  let start = peek(ts).span
  let #(label, ts) = case ts {
    [Token(lexer.Name(l), _, _), next, ..rest] ->
      case starts_pattern(next.kind) {
        True -> #(Some(l), [next, ..rest])
        False -> #(None, ts)
      }
    _ -> #(None, ts)
  }
  use #(pat, ts) <- result.try(pattern(ts))
  use #(annotation, ts) <- result.try(optional_annotation(ts))
  let end = case annotation {
    Some(t) -> t.span
    None -> pat.span
  }
  Ok(#(ast.Param(sp(start, end), label, pat, annotation), ts))
}

fn starts_pattern(kind: Kind) -> Bool {
  case kind {
    lexer.Name(_)
    | lexer.UpName(_)
    | lexer.Underscore
    | lexer.Int(_)
    | lexer.Float(_)
    | lexer.Str(_)
    | lexer.LBracket
    | lexer.LParen
    | lexer.Hash
    | lexer.LtLt -> True
    _ -> False
  }
}

// --- Types ---------------------------------------------------------------------

fn type_definition(
  start: Span,
  attrs: List(Attribute),
  publicity: ast.Publicity,
  opaque_: Bool,
  ts: Tokens,
) -> Parsed(Item) {
  use #(#(name, name_span), ts) <- result.try(expect_upname(ts, "a type name"))
  use #(#(params, header_end), ts) <- result.try(case ts {
    [Token(lexer.LParen, _, False), ..rest] -> {
      use #(#(ps, close), rest) <- result.try(
        sequence(
          rest,
          lexer.RParen,
          "`)`",
          fn(ts) {
            use #(#(n, _), ts) <- result.try(expect_name(ts, "a type parameter"))
            Ok(#(n, ts))
          },
          [],
        ),
      )
      Ok(#(#(ps, close.span), rest))
    }
    _ -> Ok(#(#([], name_span), ts))
  })
  case ts {
    [Token(lexer.Eq, _, _), ..rest] -> {
      use #(aliased, rest) <- result.try(type_(rest))
      case opaque_ {
        True ->
          Error(diagnostic.error(
            "Opaque type alias",
            name_span,
            "type aliases cannot be opaque",
          ))
        False ->
          Ok(#(
            ast.TypeAlias(
              sp(start, aliased.span),
              [],
              attrs,
              publicity,
              name,
              name_span,
              params,
              aliased,
            ),
            rest,
          ))
      }
    }
    [Token(lexer.LBrace, _, _), ..rest] -> {
      use #(#(variants, close), rest) <- result.try(variants(rest, []))
      Ok(#(
        ast.CustomType(
          sp(start, close),
          [],
          attrs,
          publicity,
          opaque_,
          name,
          name_span,
          params,
          variants,
        ),
        rest,
      ))
    }
    _ ->
      Ok(#(
        ast.ExternalType(
          sp(start, header_end),
          [],
          attrs,
          publicity,
          name,
          name_span,
          params,
        ),
        ts,
      ))
  }
}

fn variants(ts: Tokens, acc: List(Variant)) -> Parsed(#(List(Variant), Span)) {
  case ts {
    [Token(lexer.RBrace, s, _), ..rest] -> Ok(#(#(list.reverse(acc), s), rest))
    [Token(lexer.UpName(name), s, _), Token(lexer.LParen, _, False), ..rest] -> {
      use #(#(fields, close), rest) <- result.try(
        sequence(rest, lexer.RParen, "`)`", field, []),
      )
      variants(rest, [ast.Variant(sp(s, close.span), name, fields, []), ..acc])
    }
    [Token(lexer.UpName(name), s, _), ..rest] ->
      variants(rest, [ast.Variant(s, name, [], []), ..acc])
    _ -> Error(unexpected(peek(ts), "a constructor name or `}`"))
  }
}

fn field(ts: Tokens) -> Parsed(Field) {
  case relabel(ts) {
    [Token(lexer.Name(label), s, _), Token(lexer.Colon, _, _), ..rest] -> {
      use #(t, rest) <- result.try(type_(rest))
      Ok(#(ast.Field(sp(s, t.span), Some(label), t), rest))
    }
    _ -> {
      use #(t, rest) <- result.try(type_(ts))
      Ok(#(ast.Field(t.span, None, t), rest))
    }
  }
}

fn type_(ts: Tokens) -> Parsed(Type) {
  case ts {
    [Token(lexer.Fn, start, _), Token(lexer.LParen, _, _), ..rest] -> {
      use #(#(params, _), rest) <- result.try(
        sequence(rest, lexer.RParen, "`)`", fn_type_param, []),
      )
      use #(_, rest) <- result.try(expect(rest, lexer.Arrow, "`->`"))
      use #(ret, rest) <- result.try(type_(rest))
      Ok(#(ast.FnType(sp(start, ret.span), params, ret), rest))
    }
    [Token(lexer.UpName(name), s, _), ..rest] -> named_type(s, None, name, rest)
    [
      Token(lexer.Name(module), s, _),
      Token(lexer.Dot, _, False),
      Token(lexer.UpName(name), ns, False),
      ..rest
    ] -> named_type(sp(s, ns), Some(module), name, rest)
    [Token(lexer.Name(name), s, _), ..rest] ->
      case string.starts_with(name, "_") {
        True -> Ok(#(ast.HoleType(s, name), rest))
        False -> Ok(#(ast.VarType(s, name), rest))
      }
    [Token(lexer.Underscore, s, _), ..rest] -> Ok(#(ast.HoleType(s, "_"), rest))
    [Token(lexer.Hash, s, _), Token(lexer.LParen, _, False), ..rest] -> {
      use #(#(elements, close), rest) <- result.try(
        sequence(rest, lexer.RParen, "`)`", type_, []),
      )
      Ok(#(ast.TupleType(sp(s, close.span), elements), rest))
    }
    [Token(lexer.LParen, s, _), ..rest] -> {
      use #(#(elements, close, trailing), rest) <- result.try(
        paren_list(rest, type_, []),
      )
      let span = sp(s, close.span)
      case elements, trailing {
        [], _ -> Ok(#(ast.NamedType(span, None, "Nil", []), rest))
        [single], False -> Ok(#(single, rest))
        _, _ -> Ok(#(ast.TupleType(span, elements), rest))
      }
    }
    _ -> Error(unexpected(peek(ts), "a type"))
  }
}

fn fn_type_param(ts: Tokens) -> Parsed(Type) {
  // Labels in function types (`fn(x: Int) -> Int`) are documentation only.
  case ts {
    [Token(lexer.Name(_), _, _), Token(lexer.Colon, _, _), ..rest] ->
      type_(rest)
    _ -> type_(ts)
  }
}

fn named_type(
  start: Span,
  module: Option(String),
  name: String,
  ts: Tokens,
) -> Parsed(Type) {
  case ts {
    [Token(lexer.LParen, _, False), ..rest] -> {
      use #(#(args, close), rest) <- result.try(
        sequence(rest, lexer.RParen, "`)`", type_, []),
      )
      Ok(#(ast.NamedType(sp(start, close.span), module, name, args), rest))
    }
    _ -> Ok(#(ast.NamedType(start, module, name, []), ts))
  }
}

/// Parses `a, b, c)` after an opening paren, reporting whether there was a
/// trailing comma (to distinguish `(x)` from the one-tuple `(x,)`).
fn paren_list(
  ts: Tokens,
  element: fn(Tokens) -> Parsed(a),
  acc: List(a),
) -> Parsed(#(List(a), Token, Bool)) {
  case ts {
    [Token(lexer.RParen, _, _) as t, ..rest] ->
      Ok(#(#(list.reverse(acc), t, acc != []), rest))
    _ -> {
      use #(el, ts) <- result.try(element(ts))
      case ts {
        [Token(lexer.Comma, _, _), Token(lexer.RParen, _, _) as t, ..rest] ->
          Ok(#(#(list.reverse([el, ..acc]), t, True), rest))
        [Token(lexer.Comma, _, _), ..rest] ->
          paren_list(rest, element, [el, ..acc])
        [Token(lexer.RParen, _, _) as t, ..rest] ->
          Ok(#(#(list.reverse([el, ..acc]), t, acc != []), rest))
        _ -> Error(unexpected(peek(ts), "`,` or `)`"))
      }
    }
  }
}

// --- Statements ----------------------------------------------------------------

/// Parses statements after an opening `{` up to and including the `}`.
fn block_body(ts: Tokens) -> Parsed(#(List(Statement), Span)) {
  statements(ts, [])
}

fn statements(
  ts: Tokens,
  acc: List(Statement),
) -> Parsed(#(List(Statement), Span)) {
  case ts {
    [Token(lexer.RBrace, s, _), ..rest] -> Ok(#(#(list.reverse(acc), s), rest))
    [Token(lexer.Eof, _, _), ..] | [] ->
      Error(unexpected(peek(ts), "`}` to close the block"))
    _ -> {
      use #(stmt, rest) <- result.try(statement(ts))
      case peek(rest) {
        Token(lexer.RBrace, _, _) -> statements(rest, [stmt, ..acc])
        Token(_, _, True) -> statements(rest, [stmt, ..acc])
        t -> Error(unexpected(t, "a new line or `}` after this statement"))
      }
    }
  }
}

fn statement(ts: Tokens) -> Parsed(Statement) {
  case ts {
    // A bare `return` returns Nil.
    [Token(lexer.Return, s, _), Token(lexer.RBrace, _, _) as next, ..rest]
    | [Token(lexer.Return, s, _), Token(_, _, True) as next, ..rest] ->
      Ok(#(ast.Return(s, ast.Constructor(s, None, "Nil")), [next, ..rest]))
    [Token(lexer.Return, s, _), ..rest] -> {
      use #(value, rest) <- result.try(expression(rest))
      Ok(#(ast.Return(sp(s, value.span), value), rest))
    }
    [Token(lexer.Use, s, _), ..rest] -> use_(s, rest)
    [Token(lexer.Assert, s, _), ..rest] -> {
      use #(value, rest) <- result.try(expression(rest))
      case rest {
        [Token(lexer.As, _, False), ..rest] -> {
          use #(message, rest) <- result.try(expression(rest))
          Ok(#(ast.Assert(sp(s, message.span), value, Some(message)), rest))
        }
        _ -> Ok(#(ast.Assert(sp(s, value.span), value, None), rest))
      }
    }
    [Token(lexer.Name("let"), s, _), ..] ->
      Error(
        diagnostic.error("Unexpected `let`", s, "Bea has no `let` keyword")
        |> diagnostic.with_hint("Write `name = value` to bind a variable."),
      )
    _ ->
      case try_assignment(ts) {
        Some(result) -> result
        None -> {
          use #(e, rest) <- result.try(expression(ts))
          case rest {
            [Token(lexer.Eq, s, _), ..] ->
              Error(diagnostic.error(
                "Invalid assignment",
                sp(e.span, s),
                "the left side of `=` must be a pattern",
              ))
            _ -> Ok(#(ast.Expression(e), rest))
          }
        }
      }
  }
}

/// Assignments look like expressions until we reach the `=`, so we try to
/// parse a pattern first and backtrack if no `=` follows.
fn try_assignment(ts: Tokens) -> Option(Parsed(Statement)) {
  case pattern(ts) {
    Error(_) -> None
    Ok(#(pat, rest)) -> {
      let annotated = case rest {
        [Token(lexer.Colon, _, _), ..rest] ->
          case type_(rest) {
            Ok(#(t, rest)) -> Ok(#(Some(t), rest))
            Error(e) -> Error(e)
          }
        _ -> Ok(#(None, rest))
      }
      case annotated {
        Ok(#(annotation, [Token(lexer.Eq, _, _), ..rest])) ->
          Some({
            use #(value, rest) <- result.try(expression(rest))
            Ok(#(
              ast.Assign(sp(pat.span, value.span), pat, annotation, value),
              rest,
            ))
          })
        _ -> None
      }
    }
  }
}

fn use_(start: Span, ts: Tokens) -> Parsed(Statement) {
  use #(patterns, ts) <- result.try(case ts {
    [Token(lexer.LArrow, _, _), ..rest] -> Ok(#([], rest))
    _ -> use_patterns(ts, [])
  })
  use #(call, ts) <- result.try(expression(ts))
  Ok(#(ast.Use(sp(start, call.span), patterns, call), ts))
}

fn use_patterns(ts: Tokens, acc: List(UsePattern)) -> Parsed(List(UsePattern)) {
  use #(pat, ts) <- result.try(pattern(ts))
  use #(annotation, ts) <- result.try(optional_annotation(ts))
  let end = case annotation {
    Some(t) -> t.span
    None -> pat.span
  }
  let up = ast.UsePattern(sp(pat.span, end), pat, annotation)
  case ts {
    [Token(lexer.Comma, _, _), ..rest] -> use_patterns(rest, [up, ..acc])
    [Token(lexer.LArrow, _, _), ..rest] ->
      Ok(#(list.reverse([up, ..acc]), rest))
    _ -> Error(unexpected(peek(ts), "`,` or `<-`"))
  }
}

// --- Expressions ---------------------------------------------------------------

pub fn expression(ts: Tokens) -> Parsed(Expr) {
  binary(ts, 1)
}

fn binop(t: Token) -> Option(BinOp) {
  case t.kind {
    lexer.PipePipe | lexer.Or -> Some(ast.Or)
    lexer.AmpAmp | lexer.And -> Some(ast.And)
    lexer.EqEq -> Some(ast.Eq)
    lexer.NotEq -> Some(ast.NotEq)
    lexer.Less -> Some(ast.Lt)
    lexer.LessEq -> Some(ast.LtEq)
    lexer.Greater -> Some(ast.Gt)
    lexer.GreaterEq -> Some(ast.GtEq)
    lexer.LessDot -> Some(ast.LtFloat)
    lexer.LessEqDot -> Some(ast.LtEqFloat)
    lexer.GreaterDot -> Some(ast.GtFloat)
    lexer.GreaterEqDot -> Some(ast.GtEqFloat)
    lexer.Concat -> Some(ast.Concatenate)
    lexer.PipeRight -> Some(ast.Pipe)
    lexer.Plus -> Some(ast.Add)
    // A `-` at the start of a line begins a new expression.
    lexer.Minus if !t.nl_before -> Some(ast.Sub)
    lexer.PlusDot -> Some(ast.AddFloat)
    lexer.MinusDot if !t.nl_before -> Some(ast.SubFloat)
    lexer.Star -> Some(ast.Mul)
    lexer.Slash -> Some(ast.Div)
    lexer.Percent -> Some(ast.Rem)
    lexer.StarDot -> Some(ast.MulFloat)
    lexer.SlashDot -> Some(ast.DivFloat)
    _ -> None
  }
}

fn binary(ts: Tokens, min: Int) -> Parsed(Expr) {
  use #(left, ts) <- result.try(unary(ts))
  binary_loop(left, ts, min)
}

fn binary_loop(left: Expr, ts: Tokens, min: Int) -> Parsed(Expr) {
  let t = peek(ts)
  case binop(t) {
    Some(op) -> {
      let prec = ast.precedence(op)
      case prec >= min {
        False -> Ok(#(left, ts))
        True -> {
          use #(right, rest) <- result.try(binary(advance(ts), prec + 1))
          let node = case op {
            // `a |> f()?` applies `?` to the whole pipeline so far.
            ast.Pipe -> lift_try(left, right)
            _ -> ast.BinaryOp(sp(left.span, right.span), op, left, right)
          }
          binary_loop(node, rest, min)
        }
      }
    }
    None -> Ok(#(left, ts))
  }
}

fn lift_try(left: Expr, right: Expr) -> Expr {
  case head_try(right) {
    False -> ast.BinaryOp(sp(left.span, right.span), ast.Pipe, left, right)
    True ->
      case right {
        ast.Try(s, inner) -> ast.Try(sp(left.span, s), lift_try(left, inner))
        // `x |> f()?.field` is `(x |> f())?.field`
        ast.FieldAccess(s, base, f, fs) ->
          ast.FieldAccess(sp(left.span, s), lift_try(left, base), f, fs)
        ast.TupleIndex(s, base, i) ->
          ast.TupleIndex(sp(left.span, s), lift_try(left, base), i)
        ast.Call(s, fun, args) ->
          ast.Call(sp(left.span, s), lift_try(left, fun), args)
        _ -> ast.BinaryOp(sp(left.span, right.span), ast.Pipe, left, right)
      }
  }
}

/// Does a postfix chain start with `step?` (`f()?`, `f()?.x`, `f()?(y)`)?
fn head_try(e: Expr) -> Bool {
  case e {
    ast.Try(..) -> True
    ast.FieldAccess(base:, ..) | ast.TupleIndex(base:, ..) -> head_try(base)
    ast.Call(fun:, ..) -> head_try(fun)
    _ -> False
  }
}

fn unary(ts: Tokens) -> Parsed(Expr) {
  case ts {
    [Token(lexer.Minus, s, _), Token(lexer.Int(n), ns, _), ..rest] ->
      postfix(ast.Int(sp(s, ns), "-" <> n), rest)
    [Token(lexer.Minus, s, _), Token(lexer.Float(n), ns, _), ..rest]
    | [Token(lexer.MinusDot, s, _), Token(lexer.Float(n), ns, _), ..rest] ->
      postfix(ast.Float(sp(s, ns), "-" <> n), rest)
    // Gleam has no operator for negating a float; `-.x` is `float.negate(x)`.
    [Token(lexer.MinusDot, s, _), ..rest] -> {
      use #(value, rest) <- result.try(unary(rest))
      Ok(#(ast.NegateFloat(sp(s, value.span), value), rest))
    }
    [Token(lexer.Minus, s, _), ..rest] -> {
      use #(value, rest) <- result.try(unary(rest))
      Ok(#(ast.Negate(sp(s, value.span), value), rest))
    }
    [Token(lexer.Bang, s, _), ..rest] | [Token(lexer.Not, s, _), ..rest] -> {
      use #(value, rest) <- result.try(unary(rest))
      Ok(#(ast.Not(sp(s, value.span), value), rest))
    }
    _ -> {
      use #(e, rest) <- result.try(primary(ts))
      postfix(e, rest)
    }
  }
}

/// Words that are keywords in Bea but ordinary names in Gleam, so they may
/// appear as module members (`bool.and`) and labels (`return:`).
fn keyword_name(kind: Kind) -> Option(String) {
  case kind {
    lexer.Name(n) -> Some(n)
    lexer.Def -> Some("def")
    lexer.Return -> Some("return")
    lexer.Cond -> Some("cond")
    lexer.And -> Some("and")
    lexer.Or -> Some("or")
    lexer.Not -> Some("not")
    _ -> None
  }
}

fn postfix(e: Expr, ts: Tokens) -> Parsed(Expr) {
  case ts {
    [Token(lexer.Dot, _, _), Token(kind, fs, _), ..rest]
      if kind == lexer.Def
      || kind == lexer.Return
      || kind == lexer.Cond
      || kind == lexer.And
      || kind == lexer.Or
      || kind == lexer.Not
    -> {
      let assert Some(field) = keyword_name(kind)
      postfix(ast.FieldAccess(sp(e.span, fs), e, field, fs), rest)
    }
    [Token(lexer.Dot, _, _), Token(lexer.Name(field), fs, _), ..rest] ->
      postfix(ast.FieldAccess(sp(e.span, fs), e, field, fs), rest)
    [Token(lexer.Dot, _, _), Token(lexer.Int(n), ns, _), ..rest] ->
      case int.parse(n) {
        Ok(i) -> postfix(ast.TupleIndex(sp(e.span, ns), e, i), rest)
        Error(_) ->
          Error(diagnostic.error(
            "Invalid tuple index",
            ns,
            "tuple indexes must be plain integers",
          ))
      }
    [Token(lexer.Dot, _, _), Token(lexer.UpName(name), ns, _), ..rest] ->
      case e {
        ast.Var(_, module) ->
          postfix(ast.Constructor(sp(e.span, ns), Some(module), name), rest)
        _ ->
          Error(diagnostic.error(
            "Unexpected constructor",
            ns,
            "only modules can be followed by `.Constructor`",
          ))
      }
    [Token(lexer.LParen, _, False), ..rest] -> call(e, rest)
    [Token(lexer.Question, s, _), ..rest] ->
      postfix(ast.Try(sp(e.span, s), e), rest)
    _ -> Ok(#(e, ts))
  }
}

fn call(fun: Expr, ts: Tokens) -> Parsed(Expr) {
  let is_constructor = case fun {
    ast.Constructor(..) -> True
    _ -> False
  }
  case ts {
    // Gleam style record update: `Ctor(..base, field: value)`
    [Token(lexer.DotDot, _, _), ..rest] if is_constructor -> {
      use #(base, rest) <- result.try(expression(rest))
      case rest {
        [Token(lexer.Comma, _, _), ..rest] -> record_update(fun, base, rest)
        [Token(lexer.RParen, s, _), ..rest] ->
          Ok(#(ast.RecordUpdate(sp(fun.span, s), fun, base, []), rest))
        _ -> Error(unexpected(peek(rest), "`,` or `)`"))
      }
    }
    [Token(lexer.RParen, s, _), ..rest] ->
      postfix(ast.Call(sp(fun.span, s), fun, []), rest)
    _ -> {
      // Record update: `Ctor(base | field: value)`
      let update = case is_constructor, label_ahead(ts) {
        True, False ->
          case expression(ts) {
            Ok(#(base, [Token(lexer.Pipe, _, _), ..rest])) ->
              Some(#(base, rest))
            _ -> None
          }
        _, _ -> None
      }
      case update {
        Some(#(base, rest)) -> {
          use #(e, rest) <- result.try(record_update(fun, base, rest))
          postfix(e, rest)
        }
        None -> {
          use #(#(args, close), rest) <- result.try(
            sequence(ts, lexer.RParen, "`)`", argument, []),
          )
          postfix(ast.Call(sp(fun.span, close.span), fun, args), rest)
        }
      }
    }
  }
}

fn label_ahead(ts: Tokens) -> Bool {
  case relabel(ts) {
    [Token(lexer.Name(_), _, _), Token(lexer.Colon, _, _), ..] -> True
    _ -> False
  }
}

fn record_update(fun: Expr, base: Expr, ts: Tokens) -> Parsed(Expr) {
  use #(#(updates, close), rest) <- result.try(
    sequence(ts, lexer.RParen, "`)`", argument, []),
  )
  case list.find(updates, fn(a) { a.label == None }) {
    Ok(a) ->
      Error(diagnostic.error(
        "Unlabelled record update",
        a.span,
        "record updates need labelled fields, like `name: value`",
      ))
    Error(_) ->
      Ok(#(ast.RecordUpdate(sp(fun.span, close.span), fun, base, updates), rest))
  }
}

/// Lets Bea keywords be used as labels: `bool.guard(when: c, return: x)`.
fn relabel(ts: Tokens) -> Tokens {
  case ts {
    [Token(kind, s, nl), Token(lexer.Colon, _, _) as colon, ..rest] ->
      case kind, keyword_name(kind) {
        lexer.Name(_), _ -> ts
        _, Some(n) -> [Token(lexer.Name(n), s, nl), colon, ..rest]
        _, None -> ts
      }
    _ -> ts
  }
}

fn argument(ts: Tokens) -> Parsed(Arg) {
  let ts = relabel(ts)
  case ts {
    [Token(lexer.Name(label), s, _), Token(lexer.Colon, c, _), next, ..rest] ->
      case next.kind {
        lexer.Comma | lexer.RParen ->
          Ok(#(ast.Arg(sp(s, c), Some(label), None), [next, ..rest]))
        _ -> {
          use #(value, rest) <- result.try(expression([next, ..rest]))
          Ok(#(ast.Arg(sp(s, value.span), Some(label), Some(value)), rest))
        }
      }
    _ -> {
      use #(value, rest) <- result.try(expression(ts))
      Ok(#(ast.Arg(value.span, None, Some(value)), rest))
    }
  }
}

fn primary(ts: Tokens) -> Parsed(Expr) {
  case ts {
    [Token(lexer.Int(n), s, _), ..rest] -> Ok(#(ast.Int(s, n), rest))
    [Token(lexer.Float(n), s, _), ..rest] -> Ok(#(ast.Float(s, n), rest))
    [Token(lexer.Str(parts), s, _), ..rest] -> {
      use parts <- result.try(string_parts(parts, []))
      Ok(#(ast.String(s, parts), rest))
    }
    [Token(lexer.RawStr(v), s, _), ..rest] -> Ok(#(ast.RawString(s, v), rest))
    [Token(lexer.Name(n), s, _), ..rest] -> Ok(#(ast.Var(s, n), rest))
    [Token(lexer.UpName(n), s, _), ..rest] ->
      Ok(#(ast.Constructor(s, None, n), rest))
    [Token(lexer.Underscore, s, _), ..rest] -> Ok(#(ast.Hole(s), rest))

    [Token(lexer.LParen, s, _), ..rest] -> {
      use #(#(elements, close, trailing), rest) <- result.try(
        paren_list(rest, expression, []),
      )
      let span = sp(s, close.span)
      case elements, trailing {
        [], _ -> Ok(#(ast.Constructor(span, None, "Nil"), rest))
        [single], False -> Ok(#(single, rest))
        _, _ -> Ok(#(ast.Tuple(span, elements), rest))
      }
    }
    [Token(lexer.Hash, s, _), Token(lexer.LParen, _, False), ..rest] -> {
      use #(#(elements, close), rest) <- result.try(
        sequence(rest, lexer.RParen, "`)`", expression, []),
      )
      Ok(#(ast.Tuple(sp(s, close.span), elements), rest))
    }
    [Token(lexer.LBracket, s, _), ..rest] -> list_(s, rest, [])
    [Token(lexer.Percent, s, _), Token(lexer.LBrace, _, False), ..rest] ->
      map(s, rest)
    [Token(lexer.LBrace, s, _), ..rest] -> {
      use #(#(stmts, close), rest) <- result.try(block_body(rest))
      Ok(#(ast.Block(sp(s, close), stmts), rest))
    }
    [Token(lexer.Fn, s, _), ..rest] -> anonymous_fn(s, rest)
    [Token(lexer.If, s, _), ..rest] -> if_(s, rest)
    [Token(lexer.Cond, s, _), ..rest] -> {
      use #(_, rest) <- result.try(expect(
        rest,
        lexer.LBrace,
        "`{` after `cond`",
      ))
      use #(#(clauses, close), rest) <- result.try(cond_clauses(rest, []))
      Ok(#(ast.Cond(sp(s, close), clauses), rest))
    }
    [Token(lexer.Case, s, _), ..rest] -> case_(s, rest)
    [Token(lexer.Echo, s, _), next, ..rest] ->
      case starts_expression(next.kind) && !next.nl_before {
        False -> Ok(#(ast.Echo(s, None, None), [next, ..rest]))
        True -> {
          use #(value, rest) <- result.try(expression([next, ..rest]))
          case rest {
            [Token(lexer.As, _, False), ..rest] -> {
              use #(message, rest) <- result.try(expression(rest))
              Ok(#(
                ast.Echo(sp(s, message.span), Some(value), Some(message)),
                rest,
              ))
            }
            _ -> Ok(#(ast.Echo(sp(s, value.span), Some(value), None), rest))
          }
        }
      }
    [Token(lexer.Panic, s, _), ..rest] -> {
      use #(#(message, end), rest) <- result.try(optional_as(s, rest))
      Ok(#(ast.Panic(sp(s, end), message), rest))
    }
    [Token(lexer.Todo, s, _), ..rest] -> {
      use #(#(message, end), rest) <- result.try(optional_as(s, rest))
      Ok(#(ast.Todo(sp(s, end), message), rest))
    }
    [Token(lexer.LtLt, s, _), ..rest] -> {
      use #(#(segments, close), rest) <- result.try(
        sequence(
          rest,
          lexer.GtGt,
          "`>>`",
          fn(ts) { segment(ts, bit_value, expr_option_arg, ast.expr_span) },
          [],
        ),
      )
      Ok(#(ast.BitArray(sp(s, close.span), segments), rest))
    }
    [Token(lexer.Return, s, _), ..] ->
      Error(
        diagnostic.error(
          "Unexpected `return`",
          s,
          "`return` can only be used as a statement",
        )
        |> diagnostic.with_hint(
          "Put the return on its own line inside a block: `{ return x }`.",
        ),
      )
    _ -> Error(unexpected(peek(ts), "an expression"))
  }
}

fn optional_as(start: Span, ts: Tokens) -> Parsed(#(Option(Expr), Span)) {
  case ts {
    [Token(lexer.As, _, False), ..rest] -> {
      use #(message, rest) <- result.try(expression(rest))
      Ok(#(#(Some(message), message.span), rest))
    }
    _ -> Ok(#(#(None, start), ts))
  }
}

fn starts_expression(kind: Kind) -> Bool {
  case kind {
    lexer.Int(_)
    | lexer.Float(_)
    | lexer.Str(_)
    | lexer.RawStr(_)
    | lexer.Name(_)
    | lexer.UpName(_)
    | lexer.LParen
    | lexer.Hash
    | lexer.LBracket
    | lexer.Percent
    | lexer.LBrace
    | lexer.Fn
    | lexer.If
    | lexer.Cond
    | lexer.Case
    | lexer.Panic
    | lexer.Todo
    | lexer.LtLt
    | lexer.Minus
    | lexer.MinusDot
    | lexer.Bang
    | lexer.Not -> True
    _ -> False
  }
}

fn string_parts(
  parts: List(lexer.StrPart),
  acc: List(ast.StringPart),
) -> Result(List(ast.StringPart), Diagnostic) {
  case parts {
    [] -> Ok(list.reverse(acc))
    [lexer.StrText(raw, s), ..rest] ->
      string_parts(rest, [ast.Text(raw, s), ..acc])
    [lexer.StrCode(tokens, s), ..rest] -> {
      let eof = Token(lexer.Eof, Span(s.end - 1, s.end - 1), False)
      use #(e, remaining) <- result.try(expression(list.append(tokens, [eof])))
      case remaining {
        [Token(lexer.Eof, _, _), ..] ->
          string_parts(rest, [ast.Interpolation(e, s), ..acc])
        [t, ..] -> Error(unexpected(t, "`}` to end the interpolation"))
        [] -> string_parts(rest, [ast.Interpolation(e, s), ..acc])
      }
    }
  }
}

fn list_(start: Span, ts: Tokens, acc: List(Expr)) -> Parsed(Expr) {
  case ts {
    [Token(lexer.RBracket, s, _), ..rest] ->
      Ok(#(ast.List(sp(start, s), list.reverse(acc), None), rest))
    // Gleam style spread: `[a, ..rest]`
    [Token(lexer.DotDot, _, _), ..rest] -> list_tail(start, rest, acc)
    _ -> {
      use #(e, rest) <- result.try(expression(ts))
      case rest {
        [Token(lexer.Comma, _, _), ..rest] -> list_(start, rest, [e, ..acc])
        [Token(lexer.Pipe, _, _), ..rest] -> list_tail(start, rest, [e, ..acc])
        [Token(lexer.RBracket, s, _), ..rest] ->
          Ok(#(ast.List(sp(start, s), list.reverse([e, ..acc]), None), rest))
        _ -> Error(unexpected(peek(rest), "`,`, `|` or `]`"))
      }
    }
  }
}

fn list_tail(start: Span, ts: Tokens, acc: List(Expr)) -> Parsed(Expr) {
  use #(tail, rest) <- result.try(expression(ts))
  let rest = case rest {
    [Token(lexer.Comma, _, _), ..r] -> r
    _ -> rest
  }
  use #(close, rest) <- result.try(expect(rest, lexer.RBracket, "`]`"))
  case acc {
    [] ->
      Error(diagnostic.error(
        "Invalid list",
        tail.span,
        "a list tail needs at least one element before it",
      ))
    _ ->
      Ok(#(ast.List(sp(start, close.span), list.reverse(acc), Some(tail)), rest))
  }
}

fn map(start: Span, ts: Tokens) -> Parsed(Expr) {
  case ts {
    [Token(lexer.RBrace, s, _), ..rest] ->
      Ok(#(ast.Map(sp(start, s), None, []), rest))
    _ -> {
      use #(first, rest) <- result.try(expression(ts))
      case rest {
        [Token(lexer.Pipe, _, _), ..rest] -> {
          use #(#(pairs, close), rest) <- result.try(map_pairs(rest, []))
          Ok(#(ast.Map(sp(start, close), Some(first), pairs), rest))
        }
        [Token(lexer.Colon, _, _), ..rest] -> {
          use #(value, rest) <- result.try(expression(rest))
          case rest {
            [Token(lexer.Comma, _, _), ..rest] -> {
              use #(#(pairs, close), rest) <- result.try(
                map_pairs(rest, [
                  #(first, value),
                ]),
              )
              Ok(#(ast.Map(sp(start, close), None, pairs), rest))
            }
            [Token(lexer.RBrace, s, _), ..rest] ->
              Ok(#(ast.Map(sp(start, s), None, [#(first, value)]), rest))
            _ -> Error(unexpected(peek(rest), "`,` or `}`"))
          }
        }
        _ -> Error(unexpected(peek(rest), "`:` after the map key"))
      }
    }
  }
}

fn map_pairs(
  ts: Tokens,
  acc: List(#(Expr, Expr)),
) -> Parsed(#(List(#(Expr, Expr)), Span)) {
  case ts {
    [Token(lexer.RBrace, s, _), ..rest] -> Ok(#(#(list.reverse(acc), s), rest))
    _ -> {
      use #(key, rest) <- result.try(expression(ts))
      use #(_, rest) <- result.try(expect(
        rest,
        lexer.Colon,
        "`:` after the map key",
      ))
      use #(value, rest) <- result.try(expression(rest))
      case rest {
        [Token(lexer.Comma, _, _), ..rest] ->
          map_pairs(rest, [#(key, value), ..acc])
        [Token(lexer.RBrace, s, _), ..rest] ->
          Ok(#(#(list.reverse([#(key, value), ..acc]), s), rest))
        _ -> Error(unexpected(peek(rest), "`,` or `}`"))
      }
    }
  }
}

fn anonymous_fn(start: Span, ts: Tokens) -> Parsed(Expr) {
  use #(_, ts) <- result.try(expect(ts, lexer.LParen, "`(` after `fn`"))
  use #(#(params, _), ts) <- result.try(
    sequence(ts, lexer.RParen, "`)`", fn_param, []),
  )
  use #(return_type, ts) <- result.try(case ts {
    [Token(lexer.Arrow, _, _), ..rest] -> {
      use #(t, rest) <- result.try(type_(rest))
      Ok(#(Some(t), rest))
    }
    _ -> Ok(#(None, ts))
  })
  use #(_, ts) <- result.try(expect(ts, lexer.LBrace, "`{` to start the body"))
  use #(#(body, close), ts) <- result.try(block_body(ts))
  Ok(#(ast.Fn(sp(start, close), params, return_type, body), ts))
}

fn fn_param(ts: Tokens) -> Parsed(FnParam) {
  use #(pat, ts) <- result.try(pattern(ts))
  use #(annotation, ts) <- result.try(optional_annotation(ts))
  let end = case annotation {
    Some(t) -> t.span
    None -> pat.span
  }
  Ok(#(ast.FnParam(sp(pat.span, end), pat, annotation), ts))
}

fn if_(start: Span, ts: Tokens) -> Parsed(Expr) {
  use #(condition, ts) <- result.try(expression(ts))
  use #(_, ts) <- result.try(expect(ts, lexer.LBrace, "`{` after the condition"))
  use #(#(then, close), ts) <- result.try(block_body(ts))
  case ts {
    [Token(lexer.Else, _, _), Token(lexer.If, s, _), ..rest] -> {
      use #(nested, rest) <- result.try(if_(s, rest))
      Ok(#(
        ast.If(
          sp(start, nested.span),
          condition,
          then,
          Some([ast.Expression(nested)]),
        ),
        rest,
      ))
    }
    [Token(lexer.Else, _, _), Token(lexer.LBrace, _, _), ..rest] -> {
      use #(#(else_, close), rest) <- result.try(block_body(rest))
      Ok(#(ast.If(sp(start, close), condition, then, Some(else_)), rest))
    }
    [Token(lexer.Else, _, _), ..rest] ->
      Error(unexpected(peek(rest), "`{` or `if` after `else`"))
    _ -> Ok(#(ast.If(sp(start, close), condition, then, None), ts))
  }
}

fn cond_clauses(
  ts: Tokens,
  acc: List(CondClause),
) -> Parsed(#(List(CondClause), Span)) {
  case ts {
    [Token(lexer.RBrace, s, _), ..rest] -> Ok(#(#(list.reverse(acc), s), rest))
    _ -> {
      use #(condition, rest) <- result.try(case ts {
        // `_ -> x` is the catch-all clause
        [Token(lexer.Underscore, s, _), ..rest] -> Ok(#(ast.Hole(s), rest))
        _ -> expression(ts)
      })
      use #(_, rest) <- result.try(expect(rest, lexer.Arrow, "`->`"))
      use #(body, rest) <- result.try(expression(rest))
      let clause =
        ast.CondClause(sp(condition.span, body.span), condition, body)
      cond_clauses(rest, [clause, ..acc])
    }
  }
}

fn case_(start: Span, ts: Tokens) -> Parsed(Expr) {
  use #(subjects, ts) <- result.try(case_subjects(ts, []))
  use #(#(clauses, close), ts) <- result.try(
    case_clauses(ts, list.length(subjects), []),
  )
  Ok(#(ast.Case(sp(start, close), subjects, clauses), ts))
}

fn case_subjects(ts: Tokens, acc: List(Expr)) -> Parsed(List(Expr)) {
  use #(e, ts) <- result.try(expression(ts))
  case ts {
    [Token(lexer.Comma, _, _), ..rest] -> case_subjects(rest, [e, ..acc])
    [Token(lexer.LBrace, _, _), ..rest] -> Ok(#(list.reverse([e, ..acc]), rest))
    _ -> Error(unexpected(peek(ts), "`,` or `{` after the case subject"))
  }
}

fn case_clauses(
  ts: Tokens,
  arity: Int,
  acc: List(CaseClause),
) -> Parsed(#(List(CaseClause), Span)) {
  case ts {
    [Token(lexer.RBrace, s, _), ..rest] -> Ok(#(#(list.reverse(acc), s), rest))
    _ -> {
      let start = peek(ts).span
      use #(alternatives, ts) <- result.try(alternatives(ts, arity, []))
      use #(guard, ts) <- result.try(case ts {
        [Token(lexer.If, _, _), ..rest] -> {
          use #(g, rest) <- result.try(expression(rest))
          Ok(#(Some(g), rest))
        }
        _ -> Ok(#(None, ts))
      })
      use #(_, ts) <- result.try(expect(ts, lexer.Arrow, "`->`"))
      use #(body, ts) <- result.try(expression(ts))
      let clause =
        ast.CaseClause(sp(start, body.span), alternatives, guard, body)
      case_clauses(ts, arity, [clause, ..acc])
    }
  }
}

fn alternatives(
  ts: Tokens,
  arity: Int,
  acc: List(List(Pattern)),
) -> Parsed(List(List(Pattern))) {
  let start = peek(ts).span
  use #(patterns, ts) <- result.try(pattern_row(ts, []))
  case list.length(patterns) == arity {
    False ->
      Error(diagnostic.error(
        "Wrong number of patterns",
        start,
        "this case has "
          <> int.to_string(arity)
          <> " subject(s) but this clause has "
          <> int.to_string(list.length(patterns))
          <> " pattern(s)",
      ))
    True ->
      case ts {
        [Token(lexer.Pipe, _, _), ..rest] ->
          alternatives(rest, arity, [patterns, ..acc])
        _ -> Ok(#(list.reverse([patterns, ..acc]), ts))
      }
  }
}

fn pattern_row(ts: Tokens, acc: List(Pattern)) -> Parsed(List(Pattern)) {
  use #(p, ts) <- result.try(pattern(ts))
  case ts {
    [Token(lexer.Comma, _, _), ..rest] -> pattern_row(rest, [p, ..acc])
    _ -> Ok(#(list.reverse([p, ..acc]), ts))
  }
}

// --- Bit arrays ----------------------------------------------------------------

fn bit_value(ts: Tokens) -> Parsed(Expr) {
  // Segment values are operands: `<<a:8, f(x):size(4), (a + b):8>>`
  unary(ts)
}

fn expr_option_arg(ts: Tokens) -> Parsed(Expr) {
  expression(ts)
}

fn pattern_option_arg(ts: Tokens) -> Parsed(Pattern) {
  pattern(ts)
}

fn segment(
  ts: Tokens,
  value: fn(Tokens) -> Parsed(v),
  option_arg: fn(Tokens) -> Parsed(v),
  span_of: fn(v) -> Span,
) -> Parsed(ast.Segment(v)) {
  let start = peek(ts).span
  use #(v, ts) <- result.try(value(ts))
  case ts {
    [Token(lexer.Colon, _, _), ..rest] -> {
      use #(#(options, end), rest) <- result.try(
        segment_options(rest, option_arg, []),
      )
      Ok(#(ast.Segment(sp(start, end), v, options), rest))
    }
    _ -> Ok(#(ast.Segment(sp(start, span_of(v)), v, []), ts))
  }
}

fn segment_options(
  ts: Tokens,
  option_arg: fn(Tokens) -> Parsed(v),
  acc: List(ast.SegmentOption(v)),
) -> Parsed(#(List(ast.SegmentOption(v)), Span)) {
  use #(opt, ts) <- result.try(case ts {
    [Token(lexer.Name(name), s, _), Token(lexer.LParen, _, False), ..rest] -> {
      use #(arg, rest) <- result.try(option_arg(rest))
      use #(close, rest) <- result.try(expect(rest, lexer.RParen, "`)`"))
      Ok(#(ast.SegmentOption(sp(s, close.span), name, Some(arg)), rest))
    }
    [Token(lexer.Name(name), s, _), ..rest] ->
      Ok(#(ast.SegmentOption(s, name, None), rest))
    // `x:8` is shorthand for `x:size(8)`
    [Token(lexer.Int(n), s, _), ..rest] ->
      Ok(#(ast.SegmentOption(s, n, None), rest))
    _ ->
      Error(unexpected(peek(ts), "a segment option like `size(8)` or `bits`"))
  })
  case ts {
    [Token(lexer.Minus, _, _), ..rest] ->
      segment_options(rest, option_arg, [opt, ..acc])
    _ -> Ok(#(#(list.reverse([opt, ..acc]), opt.span), ts))
  }
}

// --- Patterns ------------------------------------------------------------------

pub fn pattern(ts: Tokens) -> Parsed(Pattern) {
  use #(p, ts) <- result.try(pattern_primary(ts))
  use #(p, ts) <- result.try(case p, ts {
    ast.PString(s, prefix),
      [
        Token(lexer.As, _, _),
        Token(lexer.Name(name), _, _),
        Token(lexer.Concat, _, _),
        ..rest
      ]
    -> {
      use #(r, rest) <- result.try(concat_rest(rest))
      Ok(#(ast.PConcat(sp(s, r.span), prefix, Some(name), r), rest))
    }
    ast.PString(s, prefix), [Token(lexer.Concat, _, _), ..rest] -> {
      use #(r, rest) <- result.try(concat_rest(rest))
      Ok(#(ast.PConcat(sp(s, r.span), prefix, None, r), rest))
    }
    _, _ -> Ok(#(p, ts))
  })
  pattern_as(p, ts)
}

fn concat_rest(ts: Tokens) -> Parsed(Pattern) {
  case ts {
    [Token(lexer.Name(n), s, _), ..rest] ->
      case string.starts_with(n, "_") {
        True -> Ok(#(ast.PDiscard(s, n), rest))
        False -> Ok(#(ast.PVar(s, n), rest))
      }
    [Token(lexer.Underscore, s, _), ..rest] -> Ok(#(ast.PDiscard(s, "_"), rest))
    _ -> Error(unexpected(peek(ts), "a variable name after `<>`"))
  }
}

fn pattern_as(p: Pattern, ts: Tokens) -> Parsed(Pattern) {
  case ts {
    [Token(lexer.As, _, _), Token(lexer.Name(name), s, _), ..rest] ->
      pattern_as(ast.PAssign(sp(p.span, s), p, name), rest)
    _ -> Ok(#(p, ts))
  }
}

fn pattern_primary(ts: Tokens) -> Parsed(Pattern) {
  case ts {
    [Token(lexer.Int(n), s, _), ..rest] -> Ok(#(ast.PInt(s, n), rest))
    [Token(lexer.Float(n), s, _), ..rest] -> Ok(#(ast.PFloat(s, n), rest))
    [Token(lexer.Minus, s, _), Token(lexer.Int(n), ns, _), ..rest] ->
      Ok(#(ast.PInt(sp(s, ns), "-" <> n), rest))
    [Token(lexer.Minus, s, _), Token(lexer.Float(n), ns, _), ..rest] ->
      Ok(#(ast.PFloat(sp(s, ns), "-" <> n), rest))
    [Token(lexer.Str(parts), s, _), ..rest] ->
      case parts {
        [] -> Ok(#(ast.PString(s, ""), rest))
        [lexer.StrText(raw, _)] -> Ok(#(ast.PString(s, raw), rest))
        _ ->
          Error(diagnostic.error(
            "Interpolation in pattern",
            s,
            "string patterns cannot contain `#{...}`",
          ))
      }
    [Token(lexer.RawStr(v), s, _), ..rest] ->
      Ok(#(ast.PString(s, lexer.escape_gleam_string(v)), rest))
    [Token(lexer.Name(n), s, _), ..rest] ->
      case rest {
        [Token(lexer.Dot, _, False), Token(lexer.UpName(c), cs, False), ..rest] ->
          constructor_pattern(sp(s, cs), Some(n), c, rest)
        _ ->
          case string.starts_with(n, "_") {
            True -> Ok(#(ast.PDiscard(s, n), rest))
            False -> Ok(#(ast.PVar(s, n), rest))
          }
      }
    [Token(lexer.Underscore, s, _), ..rest] -> Ok(#(ast.PDiscard(s, "_"), rest))
    [Token(lexer.UpName(n), s, _), ..rest] ->
      constructor_pattern(s, None, n, rest)
    [Token(lexer.LBracket, s, _), ..rest] -> list_pattern(s, rest, [])
    [Token(lexer.LParen, s, _), ..rest] -> {
      use #(#(elements, close, trailing), rest) <- result.try(
        paren_list(rest, pattern, []),
      )
      let span = sp(s, close.span)
      case elements, trailing {
        [], _ -> Ok(#(ast.PConstructor(span, None, "Nil", [], False), rest))
        [single], False -> Ok(#(single, rest))
        _, _ -> Ok(#(ast.PTuple(span, elements), rest))
      }
    }
    [Token(lexer.Hash, s, _), Token(lexer.LParen, _, False), ..rest] -> {
      use #(#(elements, close), rest) <- result.try(
        sequence(rest, lexer.RParen, "`)`", pattern, []),
      )
      Ok(#(ast.PTuple(sp(s, close.span), elements), rest))
    }
    [Token(lexer.LtLt, s, _), ..rest] -> {
      use #(#(segments, close), rest) <- result.try(
        sequence(
          rest,
          lexer.GtGt,
          "`>>`",
          fn(ts) {
            segment(ts, pattern_primary, pattern_option_arg, ast.pattern_span)
          },
          [],
        ),
      )
      Ok(#(ast.PBitArray(sp(s, close.span), segments), rest))
    }
    _ -> Error(unexpected(peek(ts), "a pattern"))
  }
}

fn constructor_pattern(
  start: Span,
  module: Option(String),
  name: String,
  ts: Tokens,
) -> Parsed(Pattern) {
  case ts {
    [Token(lexer.LParen, _, False), ..rest] ->
      constructor_args(start, module, name, rest, [])
    _ -> Ok(#(ast.PConstructor(start, module, name, [], False), ts))
  }
}

fn constructor_args(
  start: Span,
  module: Option(String),
  name: String,
  ts: Tokens,
  acc: List(PatternArg),
) -> Parsed(Pattern) {
  let done = fn(close: Span, spread: Bool, rest: Tokens) {
    Ok(#(
      ast.PConstructor(
        sp(start, close),
        module,
        name,
        list.reverse(acc),
        spread,
      ),
      rest,
    ))
  }
  case ts {
    [Token(lexer.RParen, s, _), ..rest] -> done(s, False, rest)
    // Partial match: `Ctor(a: x | _)` or Gleam's `Ctor(a: x, ..)`
    [
      Token(lexer.Pipe, _, _),
      Token(lexer.Underscore, _, _),
      Token(lexer.RParen, s, _),
      ..rest
    ]
    | [Token(lexer.DotDot, _, _), Token(lexer.RParen, s, _), ..rest] ->
      done(s, True, rest)
    _ -> {
      use #(arg, rest) <- result.try(pattern_arg(ts))
      let acc = [arg, ..acc]
      case rest {
        [Token(lexer.Comma, _, _), ..rest] ->
          constructor_args(start, module, name, rest, acc)
        [Token(lexer.RParen, _, _), ..]
        | [Token(lexer.Pipe, _, _), ..]
        | [Token(lexer.DotDot, _, _), ..] ->
          constructor_args(start, module, name, rest, acc)
        _ -> Error(unexpected(peek(rest), "`,`, `| _` or `)`"))
      }
    }
  }
}

fn pattern_arg(ts: Tokens) -> Parsed(PatternArg) {
  let ts = relabel(ts)
  case ts {
    [Token(lexer.Name(label), s, _), Token(lexer.Colon, c, _), next, ..rest] ->
      case next.kind {
        lexer.Comma | lexer.RParen | lexer.Pipe | lexer.DotDot ->
          Ok(#(ast.PatternArg(sp(s, c), Some(label), None), [next, ..rest]))
        _ -> {
          use #(p, rest) <- result.try(pattern([next, ..rest]))
          Ok(#(ast.PatternArg(sp(s, p.span), Some(label), Some(p)), rest))
        }
      }
    _ -> {
      use #(p, rest) <- result.try(pattern(ts))
      Ok(#(ast.PatternArg(p.span, None, Some(p)), rest))
    }
  }
}

fn list_pattern(
  start: Span,
  ts: Tokens,
  acc: List(Pattern),
) -> Parsed(Pattern) {
  case ts {
    [Token(lexer.RBracket, s, _), ..rest] ->
      Ok(#(ast.PList(sp(start, s), list.reverse(acc), None), rest))
    [Token(lexer.DotDot, _, _), ..rest] -> list_pattern_tail(start, rest, acc)
    _ -> {
      use #(p, rest) <- result.try(pattern(ts))
      case rest {
        [Token(lexer.Comma, _, _), ..rest] ->
          list_pattern(start, rest, [p, ..acc])
        [Token(lexer.Pipe, _, _), ..rest] ->
          list_pattern_tail(start, rest, [p, ..acc])
        [Token(lexer.RBracket, s, _), ..rest] ->
          Ok(#(ast.PList(sp(start, s), list.reverse([p, ..acc]), None), rest))
        _ -> Error(unexpected(peek(rest), "`,`, `|` or `]`"))
      }
    }
  }
}

fn list_pattern_tail(
  start: Span,
  ts: Tokens,
  acc: List(Pattern),
) -> Parsed(Pattern) {
  // `[a, ..]` (Gleam) means "any tail".
  use #(tail, rest) <- result.try(case ts {
    [Token(lexer.RBracket, s, _), ..] -> Ok(#(ast.PDiscard(s, "_"), ts))
    _ -> pattern(ts)
  })
  let rest = case rest {
    [Token(lexer.Comma, _, _), ..r] -> r
    _ -> rest
  }
  use #(close, rest) <- result.try(expect(rest, lexer.RBracket, "`]`"))
  Ok(#(ast.PList(sp(start, close.span), list.reverse(acc), Some(tail)), rest))
}

// --- Post processing -------------------------------------------------------------

/// Doc comments (`///`) belong to the item that follows them.
fn attach_docs(
  items: List(Item),
  comments: List(Comment),
  prev_end: Int,
  acc: List(Item),
) -> List(Item) {
  case items {
    [] -> list.reverse(acc)
    [it, ..rest] -> {
      let start = it.span.start
      let docs = docs_between(comments, prev_end, start)
      let it = case it {
        ast.Function(span, name, name_span, [clause]) ->
          ast.Function(span, name, name_span, [ast.Clause(..clause, doc: docs)])
        ast.CustomType(..) ->
          ast.CustomType(
            ..it,
            doc: docs,
            variants: variant_docs(it.variants, comments, it.name_span.end, []),
          )
        ast.TypeAlias(..) -> ast.TypeAlias(..it, doc: docs)
        ast.ExternalType(..) -> ast.ExternalType(..it, doc: docs)
        ast.Const(..) -> ast.Const(..it, doc: docs)
        _ -> it
      }
      attach_docs(rest, comments, it.span.end, [it, ..acc])
    }
  }
}

fn variant_docs(
  variants: List(Variant),
  comments: List(Comment),
  prev_end: Int,
  acc: List(Variant),
) -> List(Variant) {
  case variants {
    [] -> list.reverse(acc)
    [v, ..rest] -> {
      let v =
        ast.Variant(..v, doc: docs_between(comments, prev_end, v.span.start))
      variant_docs(rest, comments, v.span.end, [v, ..acc])
    }
  }
}

fn docs_between(comments: List(Comment), from: Int, to: Int) -> List(String) {
  comments
  |> list.filter(fn(c) {
    c.kind == lexer.Doc && c.span.start >= from && c.span.end <= to
  })
  |> list.map(fn(c) { c.text })
}

/// Consecutive `def`s with the same name are clauses of one function.
fn collapse_clauses(items: List(Item)) -> List(Item) {
  case items {
    [ast.Function(s1, name, ns, c1), ast.Function(s2, name2, _, c2), ..rest]
      if name == name2
    ->
      collapse_clauses([
        ast.Function(sp(s1, s2), name, ns, list.append(c1, c2)),
        ..rest
      ])
    [it, ..rest] -> [it, ..collapse_clauses(rest)]
    [] -> []
  }
}

/// Words Gleam reserves that Bea doesn't use itself: they'd produce invalid
/// Gleam if used as names.
const gleam_reserved = [
  "auto", "delegate", "derive", "implement", "let", "macro", "test",
]

fn reserved_words(tokens: List(Token)) -> List(Diagnostic) {
  list.filter_map(tokens, fn(t) {
    case t.kind {
      lexer.Name(n) ->
        case list.contains(gleam_reserved, n) && n != "let" {
          True ->
            Ok(diagnostic.error(
              "Reserved word",
              t.span,
              "`" <> n <> "` is reserved by Gleam and can't be used as a name",
            ))
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}
