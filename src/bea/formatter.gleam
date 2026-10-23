//// The Bea formatter.
////
//// Prints a parsed module in the canonical Bea style. Comments are not part
//// of the syntax tree, so each one is first assigned to an anchor:
////
//// - a comment on the same line after a statement or definition trails it,
//// - otherwise it leads the next element of its innermost container (block,
////   argument list, list literal, case, type definition, module...),
//// - and if there is no next element it dangles before the closing bracket.
////
//// As a safety net the output is parsed again and compared (ignoring
//// positions) with the input, and all comments must survive. If anything
//// differs the formatter refuses to format rather than change the program.

import bea/ast.{
  type Clause, type Expr, type Item, type Pattern, type Statement, type Type,
}
import bea/diagnostic.{type Diagnostic}
import bea/doc.{type Doc}
import bea/lexer.{type Comment}
import bea/parser
import bea/span.{type LineIndex, type Span, Span}
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/regexp
import gleam/string

const width = 80

pub fn format(source: String) -> Result(String, List(Diagnostic)) {
  let parsed = parser.parse_module(source)
  case parsed.errors {
    [_, ..] -> Error(parsed.errors)
    [] -> {
      let ctx = context(source, parsed.module, parsed.comments)
      let output =
        module_doc(parsed.module, ctx)
        |> doc.to_string(width)
        |> string.trim_end
        |> string.append("\n")
      verify(source, parsed, output)
    }
  }
}

/// Formatting without the safety check, for debugging the formatter.
pub fn format_unchecked(source: String) -> String {
  let parsed = parser.parse_module(source)
  let ctx = context(source, parsed.module, parsed.comments)
  module_doc(parsed.module, ctx)
  |> doc.to_string(width)
  |> string.trim_end
  |> string.append("\n")
}

fn verify(
  source: String,
  before: parser.ParseResult,
  output: String,
) -> Result(String, List(Diagnostic)) {
  let after = parser.parse_module(output)
  let same_tree = normalise(before.module) == normalise(after.module)
  let comment_texts = fn(cs: List(Comment)) {
    list.map(cs, fn(c) { string.trim(c.text) }) |> list.sort(string.compare)
  }
  let same_comments =
    comment_texts(before.comments) == comment_texts(after.comments)
  case after.errors, same_tree && same_comments {
    [], True -> Ok(output)
    _, _ ->
      Error([
        diagnostic.error(
          "Formatter bug",
          Span(0, int.min(1, string.byte_size(source))),
          "formatting this file would change its meaning, so it was left untouched",
        )
        |> diagnostic.with_hint(
          "Please report this at the Bea issue tracker with the file attached.",
        ),
      ])
  }
}

/// The tree with every position erased, as a comparable string.
fn normalise(module: ast.Module) -> String {
  let assert Ok(re) = regexp.from_string("Span\\(\\d+, \\d+\\)")
  regexp.replace(re, string.inspect(module), "Span")
}

// --- Comment anchoring --------------------------------------------------------------

type Kind {
  Lines
  Commas
}

type Container {
  Container(span: Span, kind: Kind, elements: List(Span))
}

type Ctx {
  Ctx(
    source: String,
    src: BitArray,
    index: LineIndex,
    leading: Dict(#(Span, Int), List(Comment)),
    trailing: Dict(#(Span, Int), List(Comment)),
    dangling: Dict(Span, List(Comment)),
  )
}

fn context(source: String, module: ast.Module, comments: List(Comment)) -> Ctx {
  let index = span.line_index(source)
  let module_span = Span(0, string.byte_size(source) + 1)
  let containers =
    module_containers(bit_array.from_string(source), module, module_span)
  let item_spans =
    list.flat_map(module.items, fn(it) {
      case it {
        ast.Function(clauses:, ..) -> list.map(clauses, fn(c) { c.span })
        _ -> [it.span]
      }
    })
  let attached_doc = fn(c: Comment) {
    // Doc comments right before definitions and variants live in the tree;
    // any other `///` is printed like a regular comment.
    c.kind == lexer.ModuleDoc
    || c.kind == lexer.Doc
    && {
      {
        !list.any(item_spans, fn(s) {
          s.start <= c.span.start && c.span.end <= s.end
        })
        && list.any(item_spans, fn(s) { s.start >= c.span.end })
      }
      || is_variant_doc(module, c)
    }
  }
  let empty =
    Ctx(
      source,
      bit_array.from_string(source),
      index,
      dict.new(),
      dict.new(),
      dict.new(),
    )
  comments
  |> list.filter(fn(c) { !attached_doc(c) })
  |> list.fold(empty, fn(ctx, c) {
    let container =
      containers
      |> list.filter(fn(k) {
        k.span.start <= c.span.start && c.span.end <= k.span.end
      })
      |> list.sort(fn(a, b) { int.compare(span.len(a.span), span.len(b.span)) })
      |> list.first
    case container {
      Error(_) -> ctx
      Ok(k) -> {
        let elements =
          list.sort(k.elements, fn(a, b) { int.compare(a.start, b.start) })
        let prev =
          elements
          |> list.filter(fn(e) { e.end <= c.span.start })
          |> list.last
        let next = list.find(elements, fn(e) { e.start >= c.span.end })
        let comment_line = span.position(index, c.span.start).line
        let same_line = case prev {
          Ok(p) -> span.position(index, p.end).line == comment_line
          Error(_) -> False
        }
        case prev, next, k.kind {
          Ok(p), _, _ if same_line ->
            Ctx(..ctx, trailing: push(ctx.trailing, #(k.span, p.end), c))
          _, Ok(n), _ ->
            Ctx(..ctx, leading: push(ctx.leading, #(k.span, n.start), c))
          _, _, _ -> Ctx(..ctx, dangling: push(ctx.dangling, k.span, c))
        }
      }
    }
  })
}

fn is_variant_doc(module: ast.Module, c: Comment) -> Bool {
  list.any(module.items, fn(it) {
    case it {
      ast.CustomType(span: s, variants:, ..) ->
        s.start <= c.span.start
        && c.span.end <= s.end
        && !list.any(variants, fn(v) {
          v.span.start <= c.span.start && c.span.end <= v.span.end
        })
        && list.any(variants, fn(v) { v.span.start >= c.span.end })
      _ -> False
    }
  })
}

fn push(
  d: Dict(k, List(Comment)),
  key: k,
  c: Comment,
) -> Dict(k, List(Comment)) {
  dict.upsert(d, key, fn(existing) {
    case existing {
      Some(cs) -> list.append(cs, [c])
      None -> [c]
    }
  })
}

fn module_containers(
  src: BitArray,
  module: ast.Module,
  whole: Span,
) -> List(Container) {
  let elements =
    list.flat_map(module.items, fn(it) {
      case it {
        ast.Function(clauses:, ..) -> list.map(clauses, fn(c) { c.span })
        _ -> [it.span]
      }
    })
  [
    Container(whole, Lines, elements),
    ..list.flat_map(module.items, item_containers(src, _))
  ]
}

fn item_containers(src: BitArray, it: Item) -> List(Container) {
  case it {
    ast.Function(clauses:, ..) ->
      list.flat_map(clauses, clause_containers(src, _))
    ast.CustomType(span:, variants:, ..) -> [
      Container(span, Lines, list.map(variants, fn(v) { v.span })),
      ..list.map(variants, fn(v) {
        Container(v.span, Commas, list.map(v.fields, fn(f) { f.span }))
      })
    ]
    ast.Const(value:, ..) -> expr_containers(src, value)
    ast.Import(span:, unqualified:, ..) -> [
      Container(span, Commas, list.map(unqualified, fn(u) { u.span })),
    ]
    _ -> []
  }
}

fn clause_containers(source: BitArray, c: Clause) -> List(Container) {
  let body = option.unwrap(c.body, [])
  let brace = clause_brace(source, c)
  [
    Container(
      params_span(c.span, brace),
      Commas,
      list.map(c.params, fn(p) { p.span }),
    ),
    Container(
      Span(brace, c.span.end),
      Lines,
      list.map(body, ast.statement_span),
    ),
    ..list.flatten([
      option.values([option.map(c.guard, expr_containers(source, _))])
        |> list.flatten,
      list.flat_map(body, statement_containers(source, _)),
    ])
  ]
}

fn params_span(whole: Span, brace: Int) -> Span {
  Span(whole.start, brace)
}

fn clause_brace(source: BitArray, c: Clause) -> Int {
  let header_end =
    [c.name_span.end]
    |> list.append(list.map(c.params, fn(p) { p.span.end }))
    |> list.append(
      option.values([option.map(c.return_type, fn(t) { t.span.end })]),
    )
    |> list.append(option.values([option.map(c.guard, fn(g) { g.span.end })]))
    |> list.fold(0, int.max)
  case c.body {
    Some(_) -> find_brace(source, header_end)
    None -> c.span.end
  }
}

fn fn_brace(
  source: BitArray,
  s: Span,
  params: List(ast.FnParam),
  ret: Option(Type),
) -> Int {
  let header_end =
    list.fold(
      list.append(
        list.map(params, fn(p) { p.span.end }),
        option.values([option.map(ret, fn(t) { t.span.end })]),
      ),
      s.start,
      int.max,
    )
  find_brace(source, header_end)
}

/// Offset of the first `{` at or after `from`, skipping `//` comments.
fn find_brace(source: BitArray, from: Int) -> Int {
  case bit_array_drop(source, from) {
    <<"{", _:bytes>> -> from
    <<"//", _:bytes>> -> {
      let rest = bit_array_drop(source, from)
      find_brace(source, from + line_len(rest, 0))
    }
    <<_, _:bytes>> -> find_brace(source, from + 1)
    _ -> from
  }
}

fn line_len(b: BitArray, acc: Int) -> Int {
  case b {
    <<"\n", _:bytes>> | <<>> -> acc
    <<_, rest:bytes>> -> line_len(rest, acc + 1)
    _ -> acc
  }
}

fn bit_array_drop(b: BitArray, n: Int) -> BitArray {
  case bit_array.slice(b, n, bit_array.byte_size(b) - n) {
    Ok(x) -> x
    Error(_) -> <<>>
  }
}

fn statement_containers(src: BitArray, s: Statement) -> List(Container) {
  case s {
    ast.Assign(value:, ..) | ast.Return(value:, ..) ->
      expr_containers(src, value)
    ast.Expression(e) -> expr_containers(src, e)
    ast.Use(call:, ..) -> expr_containers(src, call)
    ast.Assert(value:, message:, ..) ->
      list.flat_map([value, ..option.values([message])], expr_containers(src, _))
    ast.Guard(value:, otherwise:, ..) ->
      list.append(
        expr_containers(src, value),
        block_container(src, otherwise.span, otherwise.body),
      )
  }
}

fn block_container(
  src: BitArray,
  s: Span,
  stmts: List(Statement),
) -> List(Container) {
  [
    Container(s, Lines, list.map(stmts, ast.statement_span)),
    ..list.flat_map(stmts, statement_containers(src, _))
  ]
}

fn expr_containers(src: BitArray, e: Expr) -> List(Container) {
  let sub = fn(es: List(Expr)) { list.flat_map(es, expr_containers(src, _)) }
  case e {
    ast.Call(s, f, args) -> [
      Container(s, Commas, list.map(args, fn(a) { a.span })),
      ..sub([f, ..arg_values(args)])
    ]
    ast.RecordUpdate(s, _, b, args) -> [
      Container(s, Commas, [b.span, ..list.map(args, fn(a) { a.span })]),
      ..sub([b, ..arg_values(args)])
    ]
    ast.Tuple(s, es) -> [
      Container(s, Commas, list.map(es, fn(x) { x.span })),
      ..sub(es)
    ]
    ast.List(s, es, t) -> {
      let all = list.append(es, option.values([t]))
      [Container(s, Commas, list.map(all, fn(x) { x.span })), ..sub(all)]
    }
    ast.Map(s, b, pairs) -> {
      let spans =
        list.append(
          option.values([option.map(b, fn(b) { b.span })]),
          list.map(pairs, fn(kv) { span.merge(kv.0.span, kv.1.span) }),
        )
      [
        Container(s, Commas, spans),
        ..sub(list.append(
          option.values([b]),
          list.flat_map(pairs, fn(kv) { [kv.0, kv.1] }),
        ))
      ]
    }
    ast.Fn(s, params, ret, body) -> {
      let brace = fn_brace(src, s, params, ret)
      [
        Container(
          Span(s.start, brace),
          Commas,
          list.map(params, fn(p) { p.span }),
        ),
        Container(Span(brace, s.end), Lines, list.map(body, ast.statement_span)),
        ..list.flat_map(body, statement_containers(src, _))
      ]
    }
    ast.FnClauses(s, clauses) -> [
      Container(s, Lines, list.map(clauses, fn(c) { c.span })),
      ..list.flat_map(clauses, fn(c) {
        sub([c.body, ..option.values([c.guard])])
      })
    ]
    ast.Block(s, stmts) -> block_container(src, s, stmts)
    ast.If(s, c, t, el) -> [
      // The condition isn't an anchor: a comment after `if c {` belongs
      // to the first statement.
      Container(
        s,
        Lines,
        list.flatten([
          list.map(t, ast.statement_span),
          list.map(option.unwrap(el, []), ast.statement_span),
        ]),
      ),
      ..list.flatten([
        expr_containers(src, c),
        list.flat_map(t, statement_containers(src, _)),
        list.flat_map(option.unwrap(el, []), statement_containers(src, _)),
      ])
    ]
    ast.Cond(s, clauses) -> [
      Container(s, Lines, list.map(clauses, fn(c) { c.span })),
      ..list.flat_map(clauses, fn(c) { sub([c.condition, c.body]) })
    ]
    ast.Case(s, subjects, clauses) -> [
      Container(s, Lines, list.map(clauses, fn(c) { c.span })),
      ..list.append(
        sub(subjects),
        list.flat_map(clauses, fn(c) {
          sub([c.body, ..option.values([c.guard])])
        }),
      )
    ]
    ast.BinaryOp(s, ast.Pipe, _, _) -> {
      let #(first, steps) = pipe_chain(e, [])
      [
        Container(s, Lines, list.map([first, ..steps], fn(x) { x.span })),
        ..sub([first, ..steps])
      ]
    }
    ast.BinaryOp(_, _, l, r) -> sub([l, r])
    ast.FieldAccess(base:, ..) | ast.TupleIndex(base:, ..) -> sub([base])
    ast.Negate(_, x) | ast.NegateFloat(_, x) | ast.Not(_, x) | ast.Try(_, x) ->
      sub([x])
    ast.Echo(_, x, m) -> sub(option.values([x, m]))
    ast.Panic(_, m) | ast.Todo(_, m) -> sub(option.values([m]))
    ast.BitArray(s, segs) -> [
      Container(s, Commas, list.map(segs, fn(x) { x.span })),
      ..sub(list.map(segs, fn(x) { x.value }))
    ]
    ast.String(_, parts) ->
      list.flat_map(parts, fn(p) {
        case p {
          ast.Interpolation(x, _) -> expr_containers(src, x)
          _ -> []
        }
      })
    _ -> []
  }
}

fn arg_values(args: List(ast.Arg)) -> List(Expr) {
  option.values(list.map(args, fn(a) { a.value }))
}

fn pipe_chain(e: Expr, acc: List(Expr)) -> #(Expr, List(Expr)) {
  case e {
    ast.BinaryOp(_, ast.Pipe, l, r) -> pipe_chain(l, [r, ..acc])
    _ -> #(e, acc)
  }
}

// --- Comment printing ---------------------------------------------------------------

fn comment_text(c: Comment) -> String {
  let slashes = case c.kind {
    lexer.Regular -> "//"
    lexer.Doc -> "///"
    lexer.ModuleDoc -> "////"
  }
  string.trim_end(slashes <> c.text)
}

/// Wrap an element of a container with the comments anchored to it.
fn el(ctx: Ctx, container: Span, element: Span, d: Doc) -> Doc {
  let comments =
    dict.get(ctx.leading, #(container, element.start)) |> result_list
  let next_starts =
    list.append(list.drop(list.map(comments, fn(c) { c.span.start }), 1), [
      element.start,
    ])
  let leading =
    list.map2(comments, next_starts, fn(c, next) {
      case blank_between(ctx, c.span.end, next) {
        True -> doc.concat([t(comment_text(c)), doc.hard_line, doc.hard_line])
        False -> doc.concat([t(comment_text(c)), doc.hard_line])
      }
    })
  let trailing =
    dict.get(ctx.trailing, #(container, element.end))
    |> result_list
    |> list.map(fn(c) {
      doc.concat([t(" " <> comment_text(c)), doc.force_break])
    })
  doc.concat(list.flatten([leading, [d], trailing]))
}

fn dangling(ctx: Ctx, container: Span) -> List(Doc) {
  dict.get(ctx.dangling, container)
  |> result_list
  |> list.map(fn(c) { t(comment_text(c)) })
}

fn result_list(r: Result(List(a), Nil)) -> List(a) {
  case r {
    Ok(xs) -> xs
    Error(_) -> []
  }
}

/// Is there an empty line in the source between two offsets?
fn blank_between(ctx: Ctx, from: Int, to: Int) -> Bool {
  let a = span.position(ctx.index, from).line
  let b = span.position(ctx.index, to).line
  list.any(range(a + 1, b - 1), fn(l) {
    string.trim(span.line_text(ctx.index, l)) == ""
  })
}

fn range(from: Int, to: Int) -> List(Int) {
  case from > to {
    True -> []
    False -> [from, ..range(from + 1, to)]
  }
}

/// The first offset of an element including its leading comments.
fn element_start(ctx: Ctx, container: Span, element: Span) -> Int {
  case dict.get(ctx.leading, #(container, element.start)) {
    Ok([c, ..]) -> c.span.start
    _ -> element.start
  }
}

/// Lines separated statements/definitions with blank lines preserved.
fn lines(
  ctx: Ctx,
  container: Span,
  elements: List(#(Span, Doc)),
  always_blank: fn(Span, Span) -> Bool,
) -> Doc {
  let docs =
    list.index_map(elements, fn(pair, i) {
      let #(s, d) = pair
      let d = el(ctx, container, s, d)
      case i {
        0 -> d
        _ -> {
          let assert Ok(#(prev, _)) = list.drop(elements, i - 1) |> list.first
          let blank =
            always_blank(prev, s)
            || blank_between(ctx, prev.end, element_start(ctx, container, s))
          case blank {
            True -> doc.concat([doc.hard_line, doc.hard_line, d])
            False -> doc.concat([doc.hard_line, d])
          }
        }
      }
    })
  let dangling =
    list.map(dangling(ctx, container), fn(c) { doc.concat([doc.hard_line, c]) })
  doc.concat(list.append(docs, dangling))
}

/// A bracketed, separated sequence: one line if it fits, otherwise one
/// element per line. Each element carries the separator that follows it;
/// `trailing_comma` adds a comma after the last element when broken.
/// Comments on the same line as an element are kept after its separator.
fn seq(
  ctx: Ctx,
  container: Span,
  open: String,
  elements: List(#(Span, Doc, String)),
  close: String,
  trailing_comma: Bool,
) -> Doc {
  let count = list.length(elements)
  let docs =
    list.index_map(elements, fn(p, i) {
      let #(s, d, sep) = p
      let last = i == count - 1
      // Leading comments only; trailing ones go after the separator.
      let body = el(ctx, container, Span(s.start, -1), d)
      let separator = case last, trailing_comma {
        True, True -> doc.if_break(",", "")
        True, False -> doc.empty
        False, _ -> t(sep)
      }
      let trailing =
        dict.get(ctx.trailing, #(container, s.end))
        |> result_list
        |> list.map(fn(c) {
          doc.concat([t(" " <> comment_text(c)), doc.force_break])
        })
      let rest = case last {
        True -> doc.empty
        False -> doc.line
      }
      doc.concat(list.flatten([[body, separator], trailing, [rest]]))
    })
  let dangling =
    list.map(dangling(ctx, container), fn(c) { doc.concat([doc.hard_line, c]) })
  case docs, dangling {
    [], [] -> t(open <> close)
    _, _ ->
      doc.group(
        doc.concat([
          t(open),
          doc.nest(
            doc.concat([doc.soft_line, doc.concat(docs), doc.concat(dangling)]),
            2,
          ),
          doc.soft_line,
          t(close),
        ]),
      )
  }
}

/// A comma separated list.
fn commas(
  ctx: Ctx,
  container: Span,
  open: String,
  elements: List(#(Span, Doc)),
  close: String,
) -> Doc {
  seq(
    ctx,
    container,
    open,
    list.map(elements, fn(e) { #(e.0, e.1, ",") }),
    close,
    True,
  )
}

/// `open head | rest, rest close` (record and map updates).
fn commas_with_head(
  ctx: Ctx,
  container: Span,
  open: String,
  head: #(Span, Doc),
  rest: List(#(Span, Doc)),
  close: String,
) -> Doc {
  let head = #(head.0, head.1, " |")
  let rest = list.map(rest, fn(e) { #(e.0, e.1, ",") })
  seq(ctx, container, open, [head, ..rest], close, rest != [])
}

fn list_with_tail(ctx: Ctx, s: Span, es: List(Expr), tail: Expr) -> Doc {
  let elements = list.map(es, fn(x) { #(x.span, expr(x, ctx), ",") })
  let elements = case list.reverse(elements) {
    [#(sp, d, _), ..before] -> list.reverse([#(sp, d, " |"), ..before])
    [] -> []
  }
  seq(
    ctx,
    s,
    "[",
    list.append(elements, [#(tail.span, expr(tail, ctx), "")]),
    "]",
    False,
  )
}

// --- Printing -----------------------------------------------------------------------

fn t(s: String) -> Doc {
  doc.text(s)
}

fn flat(d: Doc) -> String {
  doc.to_string(d, 1_000_000)
}

fn module_doc(module: ast.Module, ctx: Ctx) -> Doc {
  let whole = Span(0, string.byte_size(ctx.source) + 1)
  let header = case module.module_doc {
    [] -> doc.empty
    lines ->
      doc.concat([
        doc.join(
          list.map(lines, fn(l) { t(string.trim_end("////" <> l)) }),
          doc.hard_line,
        ),
        doc.hard_line,
        doc.hard_line,
      ])
  }
  let elements =
    list.flat_map(module.items, fn(it) {
      case it {
        ast.Function(name:, clauses:, ..) ->
          list.map(clauses, fn(c) {
            #(c.span, #(name, clause_doc(name, c, ctx)))
          })
        _ -> [#(it.span, #(item_kind(it), item_doc(it, ctx)))]
      }
    })
  let kinds =
    dict.from_list(list.map(elements, fn(e) { #({ e.0 }.start, e.1.0) }))
  let always_blank = fn(prev: Span, next: Span) {
    let a = dict.get(kinds, prev.start)
    let b = dict.get(kinds, next.start)
    case a, b {
      // Consecutive imports and the clauses of one function may stay together.
      Ok("import"), Ok("import") -> False
      Ok(x), Ok(y) -> x != y || x == "type" || x == "const"
      _, _ -> True
    }
  }
  doc.concat([
    header,
    lines(ctx, whole, list.map(elements, fn(e) { #(e.0, e.1.1) }), always_blank),
  ])
}

fn item_kind(it: Item) -> String {
  case it {
    ast.Import(..) -> "import"
    ast.Const(..) -> "const"
    _ -> "type"
  }
}

fn publicity(p: ast.Publicity) -> String {
  case p {
    ast.Public -> "pub "
    ast.Private -> ""
  }
}

fn docs(lines: List(String)) -> Doc {
  doc.concat(
    list.map(lines, fn(l) {
      doc.concat([t(string.trim_end("///" <> l)), doc.hard_line])
    }),
  )
}

fn attributes(attrs: List(ast.Attribute)) -> Doc {
  doc.concat(
    list.map(attrs, fn(a) {
      let args = case a.args {
        [] -> ""
        args ->
          "("
          <> string.join(
            list.map(args, fn(arg) {
              case arg {
                ast.AttrName(n, _) -> n
                ast.AttrString(s) -> "\"" <> s <> "\""
              }
            }),
            ", ",
          )
          <> ")"
      }
      doc.concat([t("@" <> a.name <> args), doc.hard_line])
    }),
  )
}

fn type_params(params: List(String)) -> String {
  case params {
    [] -> ""
    _ -> "(" <> string.join(params, ", ") <> ")"
  }
}

fn item_doc(it: Item, ctx: Ctx) -> Doc {
  case it {
    ast.Import(span, m, _, alias, uq) -> {
      let uq_doc = case uq {
        [] -> doc.empty
        _ ->
          doc.concat([
            t("."),
            commas(
              ctx,
              span,
              "{",
              list.map(uq, fn(u) {
                let name = case u.is_type {
                  True -> "type " <> u.name
                  False -> u.name
                }
                let name = case u.alias {
                  Some(a) -> name <> " as " <> a
                  None -> name
                }
                #(u.span, t(name))
              }),
              "}",
            ),
          ])
      }
      doc.concat([
        t("import " <> m),
        uq_doc,
        case alias {
          Some(#(a, _)) -> t(" as " <> a)
          None -> doc.empty
        },
      ])
    }
    ast.CustomType(span, d, attrs, p, opaque_, name, _, params, variants) -> {
      let head =
        publicity(p)
        <> case opaque_ {
          True -> "opaque "
          False -> ""
        }
        <> "type "
        <> name
        <> type_params(params)
      let body = case variants {
        [] -> t(" {}")
        _ ->
          doc.concat([
            t(" {"),
            doc.nest(
              doc.concat([
                doc.hard_line,
                lines(
                  ctx,
                  span,
                  list.map(variants, fn(v) { #(v.span, variant_doc(v, ctx)) }),
                  fn(_, _) { False },
                ),
              ]),
              2,
            ),
            doc.hard_line,
            t("}"),
          ])
      }
      doc.concat([docs(d), attributes(attrs), t(head), body])
    }
    ast.TypeAlias(_, d, attrs, p, name, _, params, aliased) ->
      doc.concat([
        docs(d),
        attributes(attrs),
        t(publicity(p) <> "type " <> name <> type_params(params) <> " = "),
        type_doc(aliased),
      ])
    ast.ExternalType(_, d, attrs, p, name, _, params) ->
      doc.concat([
        docs(d),
        attributes(attrs),
        t(publicity(p) <> "type " <> name <> type_params(params)),
      ])
    ast.Const(_, d, attrs, p, name, _, annotation, value) ->
      doc.concat([
        docs(d),
        attributes(attrs),
        t(publicity(p) <> "const " <> name),
        annotation_doc(annotation),
        t(" ="),
        assigned(value, ctx),
      ])
    ast.Function(..) -> doc.empty
  }
}

fn variant_doc(v: ast.Variant, ctx: Ctx) -> Doc {
  let fields = case v.fields {
    [] -> doc.empty
    fs ->
      commas(
        ctx,
        v.span,
        "(",
        list.map(fs, fn(f) {
          #(f.span, case f.label {
            Some(l) -> doc.concat([t(l <> ": "), type_doc(f.type_)])
            None -> type_doc(f.type_)
          })
        }),
        ")",
      )
  }
  doc.concat([docs(v.doc), t(v.name), fields])
}

fn annotation_doc(ty: Option(Type)) -> Doc {
  case ty {
    Some(ty) -> doc.concat([t(": "), type_doc(ty)])
    None -> doc.empty
  }
}

fn type_doc(ty: Type) -> Doc {
  t(type_string(ty))
}

/// A type written the way Bea code writes it, e.g. `fn(Int) -> (a, b)`.
pub fn type_to_string(ty: Type) -> String {
  type_string(ty)
}

fn type_string(ty: Type) -> String {
  case ty {
    ast.NamedType(_, m, name, args) -> {
      let n = case m {
        Some(m) -> m <> "." <> name
        None -> name
      }
      case args {
        [] -> n
        _ -> n <> "(" <> string.join(list.map(args, type_string), ", ") <> ")"
      }
    }
    ast.VarType(_, n) | ast.HoleType(_, n) -> n
    ast.TupleType(_, [single]) -> "(" <> type_string(single) <> ",)"
    ast.TupleType(_, ts) ->
      "(" <> string.join(list.map(ts, type_string), ", ") <> ")"
    ast.FnType(_, ps, r) ->
      "fn("
      <> string.join(list.map(ps, type_string), ", ")
      <> ") -> "
      <> type_string(r)
  }
}

fn clause_doc(name: String, c: Clause, ctx: Ctx) -> Doc {
  let brace = clause_brace(ctx.src, c)
  let params =
    commas(
      ctx,
      params_span(c.span, brace),
      "(",
      list.map(c.params, fn(p) {
        #(
          p.span,
          doc.concat([
            case p.label {
              Some(l) -> t(l <> " ")
              None -> doc.empty
            },
            pattern(p.pattern, ctx),
            annotation_doc(p.annotation),
          ]),
        )
      }),
      ")",
    )
  let ret = case c.return_type {
    Some(r) -> doc.concat([t(" -> "), type_doc(r)])
    None -> doc.empty
  }
  let guard = case c.guard {
    Some(g) -> doc.concat([t(" if "), expr(g, ctx)])
    None -> doc.empty
  }
  let body = case c.body {
    Some(stmts) ->
      doc.concat([t(" "), block(ctx, Span(brace, c.span.end), stmts)])
    None -> doc.empty
  }
  doc.concat([
    docs(c.doc),
    attributes(c.attributes),
    t(publicity(c.publicity) <> "def " <> name),
    params,
    ret,
    guard,
    body,
  ])
}

/// `{` statements `}` — always on multiple lines (unless empty).
fn block(ctx: Ctx, container: Span, stmts: List(Statement)) -> Doc {
  let dangling = dangling(ctx, container)
  case stmts, dangling {
    [], [] -> t("{}")
    _, _ ->
      doc.concat([
        t("{"),
        doc.nest(
          doc.concat([
            doc.hard_line,
            lines(
              ctx,
              container,
              list.map(stmts, fn(s) {
                #(ast.statement_span(s), statement(s, ctx))
              }),
              fn(_, _) { False },
            ),
          ]),
          2,
        ),
        doc.hard_line,
        t("}"),
      ])
  }
}

fn statement(s: Statement, ctx: Ctx) -> Doc {
  case s {
    ast.Assign(_, p, annotation, value) ->
      doc.concat([
        pattern(p, ctx),
        annotation_doc(annotation),
        t(" ="),
        assigned(value, ctx),
      ])
    ast.Expression(e) -> expr(e, ctx)
    ast.Return(_, e) -> doc.concat([t("return "), expr(e, ctx)])
    ast.Use(_, ps, call) -> {
      let pats = case ps {
        [] -> t("use <- ")
        _ ->
          doc.concat([
            t("use "),
            doc.join(
              list.map(ps, fn(p) {
                doc.concat([
                  pattern(p.pattern, ctx),
                  annotation_doc(p.annotation),
                ])
              }),
              t(", "),
            ),
            t(" <- "),
          ])
      }
      doc.concat([pats, expr(call, ctx)])
    }
    ast.Assert(_, e, m) ->
      doc.concat([
        t("assert "),
        expr(e, ctx),
        case m {
          Some(m) -> doc.concat([t(" as "), expr(m, ctx)])
          None -> doc.empty
        },
      ])
    ast.Guard(_, p, annotation, value, otherwise) -> {
      let head = case p {
        Some(p) ->
          doc.concat([
            pattern(p, ctx),
            annotation_doc(annotation),
            t(" ="),
            assigned(value, ctx),
          ])
        None -> expr(value, ctx)
      }
      doc.concat([head, otherwise_doc(otherwise, ctx)])
    }
  }
}

/// `else fallback` stays on the line (moving to the next one when it
/// doesn't fit); several statements make a block.
fn otherwise_doc(o: ast.Otherwise, ctx: Ctx) -> Doc {
  let arm = case o.binding {
    Some(b) -> doc.concat([pattern(b, ctx), t(" -> ")])
    None -> doc.empty
  }
  let inline = fn(d: Doc) {
    doc.group(doc.nest(doc.concat([doc.line, t("else "), arm, d]), 2))
  }
  let leading = fn(stmt) {
    dict.has_key(ctx.leading, #(o.span, ast.statement_span(stmt).start))
  }
  case o.body, dangling(ctx, o.span) {
    [ast.Expression(e) as stmt], [] | [ast.Return(_, e) as stmt], [] ->
      case leading(stmt) {
        True -> doc.concat([t(" else "), arm, block(ctx, o.span, o.body)])
        False ->
          inline(
            el(ctx, o.span, ast.statement_span(stmt), case stmt {
              ast.Return(..) -> doc.concat([t("return "), expr(e, ctx)])
              _ -> expr(e, ctx)
            }),
          )
      }
    stmts, _ -> doc.concat([t(" else "), arm, block(ctx, o.span, stmts)])
  }
}

/// Right hand side of `=`: operator chains may move to the next line.
fn assigned(e: Expr, ctx: Ctx) -> Doc {
  case e {
    ast.BinaryOp(..) ->
      doc.group(doc.nest(doc.concat([doc.line, expr(e, ctx)]), 2))
    _ -> doc.concat([t(" "), expr(e, ctx)])
  }
}

// --- Expressions ----------------------------------------------------------------------

fn precedence(e: Expr) -> Int {
  case e {
    ast.BinaryOp(_, op, _, _) -> ast.precedence(op)
    ast.Echo(_, Some(_), _) | ast.Panic(_, Some(_)) | ast.Todo(_, Some(_)) -> 0
    _ -> 100
  }
}

fn operand(e: Expr, min: Int, ctx: Ctx) -> Doc {
  case precedence(e) < min {
    True -> doc.concat([t("("), expr(e, ctx), t(")")])
    False -> expr(e, ctx)
  }
}

fn binop(op: ast.BinOp) -> String {
  case op {
    ast.And -> "and"
    ast.Or -> "or"
    _ -> ast.binop_to_string(op)
  }
}

fn expr(e: Expr, ctx: Ctx) -> Doc {
  case e {
    ast.Int(_, text) | ast.Float(_, text) -> t(text)
    ast.String(_, parts) ->
      t(
        "\""
        <> string.concat(
          list.map(parts, fn(p) {
            case p {
              ast.Text(raw, _) -> raw
              ast.Interpolation(x, _) -> "#{" <> flat(expr(x, ctx)) <> "}"
            }
          }),
        )
        <> "\"",
      )
    ast.RawString(_, v) -> t("`" <> v <> "`")
    ast.Var(_, n) -> t(n)
    ast.Constructor(_, Some(m), n) -> t(m <> "." <> n)
    ast.Constructor(_, None, n) -> t(n)
    ast.Hole(_) -> t("_")
    ast.FieldAccess(_, base, field, _) ->
      doc.concat([operand(base, 100, ctx), t("." <> field)])
    ast.TupleIndex(_, base, i) ->
      doc.concat([operand(base, 100, ctx), t("." <> int.to_string(i))])
    ast.Call(s, f, args) -> call(ctx, s, operand(f, 100, ctx), args)
    ast.RecordUpdate(s, c, base, updates) -> {
      let updates = list.map(updates, fn(a) { #(a.span, arg(a, ctx)) })
      let base_doc = expr(base, ctx)
      // `Ctor(base | a: 1, b: 2)` — the base and its `|` travel together.
      doc.concat([
        expr(c, ctx),
        commas_with_head(ctx, s, "(", #(base.span, base_doc), updates, ")"),
      ])
    }
    ast.Tuple(s, [single]) ->
      doc.concat([t("("), el(ctx, s, single.span, expr(single, ctx)), t(",)")])
    ast.Tuple(s, es) ->
      commas(ctx, s, "(", list.map(es, fn(x) { #(x.span, expr(x, ctx)) }), ")")
    ast.List(s, es, None) ->
      commas(ctx, s, "[", list.map(es, fn(x) { #(x.span, expr(x, ctx)) }), "]")
    ast.List(s, es, Some(tail)) -> list_with_tail(ctx, s, es, tail)
    ast.Map(s, base, pairs) -> {
      let pairs =
        list.map(pairs, fn(kv) {
          #(
            span.merge(kv.0.span, kv.1.span),
            doc.concat([expr(kv.0, ctx), t(": "), expr(kv.1, ctx)]),
          )
        })
      case base {
        None -> commas(ctx, s, "%{", pairs, "}")
        Some(b) ->
          commas_with_head(ctx, s, "%{", #(b.span, expr(b, ctx)), pairs, "}")
      }
    }
    ast.Fn(s, params, ret, body) -> {
      let brace = fn_brace(ctx.src, s, params, ret)
      let body_span = Span(brace, s.end)
      let params =
        commas(
          ctx,
          Span(s.start, brace),
          "(",
          list.map(params, fn(p) {
            #(
              p.span,
              doc.concat([pattern(p.pattern, ctx), annotation_doc(p.annotation)]),
            )
          }),
          ")",
        )
      let ret = case ret {
        Some(r) -> doc.concat([t(" -> "), type_doc(r)])
        None -> doc.empty
      }
      let body = case body, dangling(ctx, body_span) {
        [ast.Expression(x)], [] ->
          doc.group(
            doc.concat([
              t("{"),
              doc.nest(
                doc.concat([doc.line, el(ctx, body_span, x.span, expr(x, ctx))]),
                2,
              ),
              doc.line,
              t("}"),
            ]),
          )
        _, _ -> block(ctx, body_span, body)
      }
      doc.concat([t("fn"), params, ret, t(" "), body])
    }
    ast.FnClauses(s, clauses) ->
      doc.concat([
        t("fn {"),
        doc.nest(
          doc.concat([
            doc.hard_line,
            lines(
              ctx,
              s,
              list.map(clauses, fn(c) { #(c.span, case_clause(c, ctx)) }),
              fn(_, _) { False },
            ),
          ]),
          2,
        ),
        doc.hard_line,
        t("}"),
      ])
    ast.Block(s, stmts) -> block(ctx, s, stmts)
    ast.If(s, c, then, el) -> if_doc(ctx, s, c, then, el)
    ast.Cond(s, clauses) ->
      doc.concat([
        t("cond {"),
        doc.nest(
          doc.concat([
            doc.hard_line,
            lines(
              ctx,
              s,
              list.map(clauses, fn(c) {
                #(
                  c.span,
                  doc.concat([
                    expr(c.condition, ctx),
                    t(" ->"),
                    arm_body(c.body, ctx),
                  ]),
                )
              }),
              fn(_, _) { False },
            ),
          ]),
          2,
        ),
        doc.hard_line,
        t("}"),
      ])
    ast.Case(s, subjects, clauses) ->
      doc.concat([
        t("case "),
        doc.join(list.map(subjects, expr(_, ctx)), t(", ")),
        t(" {"),
        doc.nest(
          doc.concat([
            doc.hard_line,
            lines(
              ctx,
              s,
              list.map(clauses, fn(c) { #(c.span, case_clause(c, ctx)) }),
              fn(_, _) { False },
            ),
          ]),
          2,
        ),
        doc.hard_line,
        t("}"),
      ])
    ast.BinaryOp(s, ast.Pipe, _, _) -> {
      let #(first, steps) = pipe_chain(e, [])
      let p = ast.precedence(ast.Pipe)
      // Pipelines written over several lines stay that way.
      let multiline =
        span.position(ctx.index, s.start).line
        != span.position(ctx.index, s.end).line
      doc.group(
        doc.concat([
          case multiline {
            True -> doc.force_break
            False -> doc.empty
          },
          el(ctx, s, first.span, operand(first, p, ctx)),
          ..list.map(steps, fn(step) {
            doc.concat([
              doc.line,
              el(
                ctx,
                s,
                step.span,
                doc.concat([t("|> "), operand(step, p + 1, ctx)]),
              ),
            ])
          })
        ]),
      )
    }
    ast.BinaryOp(_, op, l, r) -> {
      let p = ast.precedence(op)
      doc.concat([
        operand(l, p, ctx),
        t(" " <> binop(op) <> " "),
        operand(r, p + 1, ctx),
      ])
    }
    ast.Negate(_, x) ->
      case x {
        // `-5` would read back as a literal; keep the negation explicit.
        ast.Int(..) | ast.Float(..) ->
          doc.concat([t("-("), expr(x, ctx), t(")")])
        _ -> doc.concat([t("-"), operand(x, 100, ctx)])
      }
    ast.NegateFloat(_, x) ->
      case x {
        ast.Float(..) -> doc.concat([t("-.("), expr(x, ctx), t(")")])
        _ -> doc.concat([t("-."), operand(x, 100, ctx)])
      }
    ast.Not(_, x) -> doc.concat([t("not "), operand(x, 100, ctx)])
    ast.Echo(_, None, _) -> t("echo")
    ast.Echo(_, Some(x), m) ->
      doc.concat([
        t("echo "),
        expr(x, ctx),
        case m {
          Some(m) -> doc.concat([t(" as "), expr(m, ctx)])
          None -> doc.empty
        },
      ])
    ast.Try(_, x) -> doc.concat([operand(x, 100, ctx), t("?")])
    ast.Panic(_, m) -> keyword("panic", m, ctx)
    ast.Todo(_, m) -> keyword("todo", m, ctx)
    ast.BitArray(s, segs) ->
      commas(
        ctx,
        s,
        "<<",
        list.map(segs, fn(seg) { #(seg.span, segment(seg, expr(_, ctx))) }),
        ">>",
      )
  }
}

fn keyword(kw: String, m: Option(Expr), ctx: Ctx) -> Doc {
  case m {
    Some(m) -> doc.concat([t(kw <> " as "), operand(m, 100, ctx)])
    None -> t(kw)
  }
}

fn arg(a: ast.Arg, ctx: Ctx) -> Doc {
  case a.label, a.value {
    Some(l), Some(v) -> doc.concat([t(l <> ": "), expr(v, ctx)])
    Some(l), None -> t(l <> ":")
    None, Some(v) -> expr(v, ctx)
    None, None -> doc.empty
  }
}

/// Calls hug a trailing anonymous function:
/// `list.map(xs, fn(x) {` ... `})`.
fn call(ctx: Ctx, s: Span, callee: Doc, args: List(ast.Arg)) -> Doc {
  let elements = list.map(args, fn(a) { #(a.span, arg(a, ctx)) })
  let regular = doc.concat([callee, commas(ctx, s, "(", elements, ")")])
  let huggable = fn(a: ast.Arg) {
    case a.value {
      Some(ast.Fn(..)) | Some(ast.List(..)) | Some(ast.Map(..)) -> True
      _ -> False
    }
  }
  case list.reverse(args) {
    [last, ..init_rev] if last.label == None ->
      case huggable(last) {
        False -> regular
        True -> {
          let init = list.reverse(init_rev)
          let init_flat =
            string.join(list.map(init, fn(a) { flat(arg(a, ctx)) }), ", ")
          let has_comments =
            list.any(args, fn(a) {
              dict.has_key(ctx.leading, #(s, a.span.start))
            })
            || dict.has_key(ctx.dangling, s)
          case
            has_comments
            || string.contains(init_flat, "\n")
            || string.length(init_flat) > 50
          {
            True -> regular
            False -> {
              let prefix = case init {
                [] -> ""
                _ -> init_flat <> ", "
              }
              doc.concat([callee, t("(" <> prefix), arg(last, ctx), t(")")])
            }
          }
        }
      }
    _ -> regular
  }
}

fn if_doc(
  ctx: Ctx,
  s: Span,
  c: Expr,
  then: List(Statement),
  else_: Option(List(Statement)),
) -> Doc {
  let head = doc.concat([t("if "), expr(c, ctx), t(" "), block(ctx, s, then)])
  case else_ {
    None -> head
    Some([ast.Expression(ast.If(s2, c2, t2, e2))]) ->
      doc.concat([head, t(" else "), if_doc(ctx, s2, c2, t2, e2)])
    Some(stmts) -> doc.concat([head, t(" else "), block(ctx, s, stmts)])
  }
}

fn case_clause(c: ast.CaseClause, ctx: Ctx) -> Doc {
  let alternatives =
    list.map(c.alternatives, fn(alt) {
      doc.join(list.map(alt, pattern(_, ctx)), t(", "))
    })
  doc.concat([
    doc.join(alternatives, t(" | ")),
    case c.guard {
      Some(g) -> doc.concat([t(" if "), expr(g, ctx)])
      None -> doc.empty
    },
    t(" ->"),
    arm_body(c.body, ctx),
  ])
}

fn arm_body(body: Expr, ctx: Ctx) -> Doc {
  case body {
    ast.Block(..) | ast.Fn(..) | ast.Case(..) | ast.If(..) | ast.Cond(..) ->
      doc.concat([t(" "), expr(body, ctx)])
    _ -> doc.group(doc.nest(doc.concat([doc.line, expr(body, ctx)]), 2))
  }
}

fn segment(seg: ast.Segment(v), value: fn(v) -> Doc) -> Doc {
  case seg.options {
    [] -> value(seg.value)
    opts ->
      doc.concat([
        value(seg.value),
        t(":"),
        doc.join(
          list.map(opts, fn(o) {
            case o.arg {
              Some(a) -> doc.concat([t(o.name <> "("), value(a), t(")")])
              None -> t(o.name)
            }
          }),
          t("-"),
        ),
      ])
  }
}

// --- Patterns -----------------------------------------------------------------------

fn pattern(p: Pattern, ctx: Ctx) -> Doc {
  case p {
    ast.PInt(_, text) | ast.PFloat(_, text) -> t(text)
    ast.PString(_, raw) -> t("\"" <> raw <> "\"")
    ast.PVar(_, n) | ast.PDiscard(_, n) -> t(n)
    ast.PTuple(s, [single]) ->
      doc.concat([
        t("("),
        el(ctx, s, single.span, pattern(single, ctx)),
        t(",)"),
      ])
    ast.PTuple(s, ps) ->
      commas(
        ctx,
        s,
        "(",
        list.map(ps, fn(x) { #(x.span, pattern(x, ctx)) }),
        ")",
      )
    ast.PList(s, ps, None) ->
      commas(
        ctx,
        s,
        "[",
        list.map(ps, fn(x) { #(x.span, pattern(x, ctx)) }),
        "]",
      )
    ast.PList(_, ps, Some(tail)) ->
      t(
        "["
        <> string.join(list.map(ps, fn(x) { flat(pattern(x, ctx)) }), ", ")
        <> " | "
        <> flat(pattern(tail, ctx))
        <> "]",
      )
    ast.PConstructor(_, m, name, args, spread) -> {
      let n = case m {
        Some(m) -> m <> "." <> name
        None -> name
      }
      let args_text =
        list.map(args, fn(a) {
          case a.label, a.value {
            Some(l), Some(v) -> l <> ": " <> flat(pattern(v, ctx))
            Some(l), None -> l <> ":"
            None, Some(v) -> flat(pattern(v, ctx))
            None, None -> ""
          }
        })
        |> string.join(", ")
      case args, spread {
        [], False -> t(n)
        [], True -> t(n <> "(| _)")
        _, False -> t(n <> "(" <> args_text <> ")")
        _, True -> t(n <> "(" <> args_text <> " | _)")
      }
    }
    ast.PAssign(_, inner, name) ->
      doc.concat([pattern(inner, ctx), t(" as " <> name)])
    ast.PConcat(_, prefix, name, rest) ->
      doc.concat([
        t("\"" <> prefix <> "\""),
        case name {
          Some(n) -> t(" as " <> n)
          None -> doc.empty
        },
        t(" <> "),
        pattern(rest, ctx),
      ])
    ast.PBitArray(s, segs) ->
      commas(
        ctx,
        s,
        "<<",
        list.map(segs, fn(seg) { #(seg.span, segment(seg, pattern(_, ctx))) }),
        ">>",
      )
  }
}
