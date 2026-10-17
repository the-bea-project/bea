//// A small Wadler-style pretty printer.
////
//// Both the Gleam code generator and the Bea formatter build `Doc`s. The one
//// addition over a textbook printer is `mark`: it records which range of the
//// *output* was produced for a given *source* span. Rendering returns those
//// ranges, which is the raw material for Bea's source maps.

import bea/span.{type Span}
import gleam/list
import gleam/string

pub opaque type Doc {
  Text(String)
  /// A line break when the enclosing group breaks, otherwise `flat`.
  Line(flat: String)
  /// A line break that is always taken (and breaks enclosing groups).
  HardLine
  /// Text that depends on whether the enclosing group broke.
  IfBreak(broken: String, flat: String)
  /// Renders nothing but forces the enclosing group to break.
  ForceBreak
  Nest(Int, Doc)
  Group(Doc)
  Concat(List(Doc))
  Mark(Span, Doc)
}

pub type Mapping {
  /// `generated` is a byte range of the rendered output; `source` is the
  /// span of the input that produced it.
  Mapping(generated: Span, source: Span)
}

pub const empty = Concat([])

pub fn text(s: String) -> Doc {
  Text(s)
}

/// A space when flat, a newline when broken.
pub const line = Line(" ")

/// Nothing when flat, a newline when broken.
pub const soft_line = Line("")

pub const hard_line = HardLine

pub const force_break = ForceBreak

pub fn if_break(broken: String, flat: String) -> Doc {
  IfBreak(broken, flat)
}

pub fn nest(doc: Doc, by: Int) -> Doc {
  Nest(by, doc)
}

pub fn group(doc: Doc) -> Doc {
  Group(doc)
}

pub fn concat(docs: List(Doc)) -> Doc {
  Concat(docs)
}

pub fn append(a: Doc, b: Doc) -> Doc {
  Concat([a, b])
}

pub fn mark(doc: Doc, span: Span) -> Doc {
  Mark(span, doc)
}

pub fn join(docs: List(Doc), separator: Doc) -> Doc {
  Concat(list.intersperse(docs, separator))
}

/// `open` elements `close`, with elements separated by commas, breaking one
/// element per line (with a trailing comma) when it doesn't fit.
pub fn comma_list(open: String, docs: List(Doc), close: String) -> Doc {
  case docs {
    [] -> Text(open <> close)
    _ ->
      Group(
        Concat([
          Text(open),
          Nest(2, Concat([soft_line, join(docs, Concat([Text(","), line]))])),
          IfBreak(",", ""),
          soft_line,
          Text(close),
        ]),
      )
  }
}

/// Render a document to a string, also returning source mappings.
pub fn render(doc: Doc, width: Int) -> #(String, List(Mapping)) {
  let st = run(R([], 0, 0, []), width, [Cmd(0, Break, doc)])
  #(string.concat(list.reverse(st.out)), list.reverse(st.mappings))
}

pub fn to_string(doc: Doc, width: Int) -> String {
  render(doc, width).0
}

type Mode {
  Flat
  Break
}

type Cmd {
  Cmd(indent: Int, mode: Mode, doc: Doc)
  EndMark(span: Span, start: Int)
}

type R {
  /// out: reversed output chunks; col: current column; offset: current byte
  /// offset; mappings: reversed.
  R(out: List(String), col: Int, offset: Int, mappings: List(Mapping))
}

fn emit(st: R, s: String) -> R {
  case s {
    "" -> st
    _ -> {
      let size = string.byte_size(s)
      let col = case string.split(s, "\n") |> list.reverse {
        [last, _, ..] -> string.length(last)
        _ -> st.col + string.length(s)
      }
      R(..st, out: [s, ..st.out], col: col, offset: st.offset + size)
    }
  }
}

/// Emits a newline, dropping trailing spaces from the current line.
fn newline(st: R, indent: Int) -> R {
  let st = trim_trailing(st)
  let s = "\n" <> string.repeat(" ", indent)
  R(
    ..st,
    out: [s, ..st.out],
    col: indent,
    offset: st.offset + string.byte_size(s),
  )
}

fn trim_trailing(st: R) -> R {
  case st.out {
    [last, ..rest] -> {
      let trimmed = trim_end_spaces(last)
      case trimmed == last {
        True -> st
        False -> {
          let removed = string.byte_size(last) - string.byte_size(trimmed)
          let st = R(..st, out: rest, offset: st.offset - removed)
          case trimmed {
            "" -> trim_trailing(st)
            _ -> R(..st, out: [trimmed, ..st.out])
          }
        }
      }
    }
    [] -> st
  }
}

fn trim_end_spaces(s: String) -> String {
  case string.ends_with(s, " ") {
    True -> trim_end_spaces(string.drop_end(s, 1))
    False -> s
  }
}

fn run(st: R, width: Int, cmds: List(Cmd)) -> R {
  case cmds {
    [] -> st
    [EndMark(span, start), ..rest] -> {
      // Marks that ended up covering only trailing whitespace are dropped.
      let m = Mapping(span.Span(start, st.offset), span)
      run(R(..st, mappings: [m, ..st.mappings]), width, rest)
    }
    [Cmd(i, mode, doc), ..rest] ->
      case doc {
        Text(s) -> run(emit(st, s), width, rest)
        Concat(docs) ->
          run(
            st,
            width,
            list.fold_right(docs, rest, fn(acc, d) { [Cmd(i, mode, d), ..acc] }),
          )
        Nest(n, d) -> run(st, width, [Cmd(i + n, mode, d), ..rest])
        Mark(span, d) ->
          run(st, width, [Cmd(i, mode, d), EndMark(span, st.offset), ..rest])
        HardLine -> run(newline(st, i), width, rest)
        ForceBreak -> run(st, width, rest)
        IfBreak(broken, flat) ->
          case mode {
            Flat -> run(emit(st, flat), width, rest)
            Break -> run(emit(st, broken), width, rest)
          }
        Line(flat) ->
          case mode {
            Flat -> run(emit(st, flat), width, rest)
            Break -> run(newline(st, i), width, rest)
          }
        Group(d) ->
          case mode {
            Flat -> run(st, width, [Cmd(i, Flat, d), ..rest])
            Break ->
              case fits(width - st.col, [Cmd(i, Flat, d), ..rest]) {
                True -> run(st, width, [Cmd(i, Flat, d), ..rest])
                False -> run(st, width, [Cmd(i, Break, d), ..rest])
              }
          }
      }
  }
}

/// Does everything up to the next line break fit in `remaining` columns?
fn fits(remaining: Int, cmds: List(Cmd)) -> Bool {
  case remaining < 0 {
    True -> False
    False ->
      case cmds {
        [] -> True
        [EndMark(..), ..rest] -> fits(remaining, rest)
        [Cmd(i, mode, doc), ..rest] ->
          case doc {
            Text(s) ->
              case string.split_once(s, "\n") {
                // Multi-line text (e.g. a multi-line string literal): only
                // the first line counts.
                Ok(#(first, _)) -> remaining - string.length(first) >= 0
                Error(_) -> fits(remaining - string.length(s), rest)
              }
            Concat(docs) ->
              fits(
                remaining,
                list.fold_right(docs, rest, fn(acc, d) {
                  [Cmd(i, mode, d), ..acc]
                }),
              )
            Nest(n, d) -> fits(remaining, [Cmd(i + n, mode, d), ..rest])
            Mark(_, d) -> fits(remaining, [Cmd(i, mode, d), ..rest])
            // Groups after the one being measured keep the mode of their
            // parent, so a break inside them ends the measurement.
            Group(d) -> fits(remaining, [Cmd(i, mode, d), ..rest])
            HardLine ->
              case mode {
                Break -> True
                Flat -> False
              }
            ForceBreak ->
              case mode {
                Break -> fits(remaining, rest)
                Flat -> False
              }
            IfBreak(broken, flat) ->
              case mode {
                Flat -> fits(remaining - string.length(flat), rest)
                Break -> fits(remaining - string.length(broken), rest)
              }
            Line(flat) ->
              case mode {
                Break -> True
                Flat -> fits(remaining - string.length(flat), rest)
              }
          }
      }
  }
}

/// True if the doc contains a hard line break anywhere, i.e. it can never be
/// rendered on one line.
pub fn has_hard_line(doc: Doc) -> Bool {
  case doc {
    HardLine -> True
    Text(s) -> string.contains(s, "\n")
    ForceBreak -> True
    Line(_) | IfBreak(..) -> False
    Nest(_, d) | Group(d) | Mark(_, d) -> has_hard_line(d)
    Concat(ds) -> list.any(ds, has_hard_line)
  }
}
