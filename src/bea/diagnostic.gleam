//// Compiler diagnostics and their terminal rendering.

import bea/span.{type Span}
import bea/style
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Severity {
  Error
  Warning
}

pub type Diagnostic {
  Diagnostic(
    severity: Severity,
    title: String,
    span: Span,
    label: String,
    hint: Option(String),
  )
}

pub fn error(title: String, span: Span, label: String) -> Diagnostic {
  Diagnostic(Error, title, span, label, None)
}

pub fn warning(title: String, span: Span, label: String) -> Diagnostic {
  Diagnostic(Warning, title, span, label, None)
}

pub fn with_hint(diagnostic: Diagnostic, hint: String) -> Diagnostic {
  Diagnostic(..diagnostic, hint: Some(hint))
}

pub fn is_error(diagnostic: Diagnostic) -> Bool {
  diagnostic.severity == Error
}

/// Render a diagnostic in the same visual style as the Gleam compiler, so
/// mixed Bea/Gleam output reads consistently.
pub fn render(
  diagnostic: Diagnostic,
  path: String,
  source: String,
  colour: Bool,
) -> String {
  render_highlighted(diagnostic, path, source, colour, fn(line) { line })
}

/// Like `render`, colouring the source line with `highlight` (see
/// `bea/highlight`, which can't be used from here).
pub fn render_highlighted(
  diagnostic: Diagnostic,
  path: String,
  source: String,
  colour: Bool,
  highlight: fn(String) -> String,
) -> String {
  let index = span.line_index(source)
  let start = span.position(index, diagnostic.span.start)
  let end = span.position(index, diagnostic.span.end)
  let line_no = int.to_string(start.line + 1)
  let gutter = string.repeat(" ", string.length(line_no))
  let line_text = span.line_text(index, start.line)
  let width = case end.line == start.line {
    True -> int.max(end.column - start.column, 1)
    False -> int.max(string.length(line_text) - start.column, 1)
  }
  // Columns are byte based; convert the prefix to a character count so the
  // caret lines up with non-ASCII text.
  let prefix_chars =
    string.length(span.text(
      line_text,
      span.Span(0, int.min(start.column, string.byte_size(line_text))),
    ))
  let #(kind, paint) = case diagnostic.severity {
    Error -> #("error", red)
    Warning -> #("warning", yellow)
  }
  let plain = fn(s) { s }
  let #(paint, bold, label, dim, code) = case colour {
    True -> #(paint, style.bold, style.error, style.dim, highlight)
    False -> #(plain, plain, plain, plain, plain)
  }
  let label = case diagnostic.severity {
    Error -> label
    Warning if colour -> style.warning
    Warning -> plain
  }
  let header = label(kind) <> bold(": " <> diagnostic.title)
  let location =
    path
    <> ":"
    <> int.to_string(start.line + 1)
    <> ":"
    <> int.to_string(prefix_chars + 1)
  let caret =
    dim(gutter <> " │ ")
    <> string.repeat(" ", prefix_chars)
    <> paint(string.repeat("^", width) <> " " <> diagnostic.label)
  let hint = case diagnostic.hint {
    Some(h) -> "\n" <> bold("Hint:") <> " " <> h <> "\n"
    None -> ""
  }
  [
    header,
    dim(gutter <> " ┌─ ") <> location,
    dim(gutter <> " │"),
    dim(line_no <> " │ ") <> code(line_text),
    caret,
  ]
  |> string.join("\n")
  |> string.append(hint)
  |> string.append("\n")
}

pub fn render_all(
  diagnostics: List(Diagnostic),
  path: String,
  source: String,
  colour: Bool,
) -> String {
  render_all_highlighted(diagnostics, path, source, colour, fn(line) { line })
}

pub fn render_all_highlighted(
  diagnostics: List(Diagnostic),
  path: String,
  source: String,
  colour: Bool,
  highlight: fn(String) -> String,
) -> String {
  diagnostics
  |> list.map(render_highlighted(_, path, source, colour, highlight))
  |> string.join("\n")
}

fn red(text: String) -> String {
  "\u{001b}[31m" <> text <> "\u{001b}[0m"
}

fn yellow(text: String) -> String {
  "\u{001b}[33m" <> text <> "\u{001b}[0m"
}
