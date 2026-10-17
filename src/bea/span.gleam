//// Source positions.
////
//// Every span is a half-open range of **byte** offsets into the UTF-8 source
//// text. Line/column conversion is done lazily through a `LineIndex`, which is
//// what the CLI (for error messages) and the LSP (for editor positions) use.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/string

pub type Span {
  Span(start: Int, end: Int)
}

pub const empty = Span(0, 0)

pub fn merge(a: Span, b: Span) -> Span {
  Span(int.min(a.start, b.start), int.max(a.end, b.end))
}

pub fn contains(span: Span, offset: Int) -> Bool {
  offset >= span.start && offset <= span.end
}

pub fn len(span: Span) -> Int {
  span.end - span.start
}

/// A zero-based line/column position. Columns are byte offsets within the
/// line; use `utf16_column` when talking to an LSP client.
pub type Position {
  Position(line: Int, column: Int)
}

/// Byte offsets at which each line starts, plus the source itself so that
/// columns can be converted to UTF-16 code units for editors.
pub opaque type LineIndex {
  LineIndex(starts: List(Int), source: BitArray, length: Int)
}

pub fn line_index(source: String) -> LineIndex {
  let bytes = bit_array.from_string(source)
  LineIndex(
    starts: list.reverse(scan_lines(bytes, 0, [0])),
    source: bytes,
    length: bit_array.byte_size(bytes),
  )
}

fn scan_lines(bytes: BitArray, offset: Int, acc: List(Int)) -> List(Int) {
  case bytes {
    <<"\n", rest:bytes>> -> scan_lines(rest, offset + 1, [offset + 1, ..acc])
    <<_, rest:bytes>> -> scan_lines(rest, offset + 1, acc)
    _ -> acc
  }
}

pub fn line_count(index: LineIndex) -> Int {
  list.length(index.starts)
}

/// Converts a byte offset into a zero-based line and byte column.
pub fn position(index: LineIndex, offset: Int) -> Position {
  let offset = int.clamp(offset, 0, index.length)
  find_line(index.starts, offset, 0, 0)
}

fn find_line(
  starts: List(Int),
  offset: Int,
  line: Int,
  start: Int,
) -> Position {
  case starts {
    [s, ..rest] if s <= offset -> find_line(rest, offset, line + 1, s)
    _ -> Position(int.max(line - 1, 0), offset - start)
  }
}

/// Byte offset at which a zero-based line starts (clamped).
pub fn line_start(index: LineIndex, line: Int) -> Int {
  case list.drop(index.starts, line) {
    [s, ..] -> s
    [] -> index.length
  }
}

/// Byte offset at which a zero-based line ends (before its newline).
pub fn line_end(index: LineIndex, line: Int) -> Int {
  case list.drop(index.starts, line + 1) {
    [s, ..] -> s - 1
    [] -> index.length
  }
}

/// The text of a zero-based line, without its trailing newline.
pub fn line_text(index: LineIndex, line: Int) -> String {
  let start = line_start(index, line)
  let end = line_end(index, line)
  slice(index.source, start, end - start)
  |> string.replace("\r", "")
}

/// Converts a line/byte-column position to a byte offset.
pub fn offset(index: LineIndex, position: Position) -> Int {
  let start = line_start(index, position.line)
  let end = line_end(index, position.line)
  int.clamp(start + position.column, start, end)
}

/// The column of a byte offset measured in UTF-16 code units (LSP default).
pub fn utf16_position(index: LineIndex, offset: Int) -> Position {
  let Position(line, column) = position(index, offset)
  let start = line_start(index, line)
  let prefix = slice(index.source, start, column)
  Position(line, utf16_length(prefix))
}

/// Converts an LSP (UTF-16 based) position to a byte offset.
pub fn utf16_offset(index: LineIndex, position: Position) -> Int {
  let start = line_start(index, position.line)
  let end = line_end(index, position.line)
  let text = slice(index.source, start, end - start)
  start + utf16_to_byte_column(string.to_graphemes(text), position.column, 0)
}

fn utf16_to_byte_column(
  graphemes: List(String),
  units: Int,
  bytes: Int,
) -> Int {
  case graphemes {
    _ if units <= 0 -> bytes
    [] -> bytes
    [g, ..rest] ->
      utf16_to_byte_column(
        rest,
        units - utf16_length(g),
        bytes + string.byte_size(g),
      )
  }
}

pub fn utf16_length(text: String) -> Int {
  string.to_utf_codepoints(text)
  |> list.fold(0, fn(acc, cp) {
    case string.utf_codepoint_to_int(cp) > 0xFFFF {
      True -> acc + 2
      False -> acc + 1
    }
  })
}

fn slice(bytes: BitArray, start: Int, length: Int) -> String {
  case bit_array.slice(bytes, start, int.max(length, 0)) {
    Ok(b) ->
      case bit_array.to_string(b) {
        Ok(s) -> s
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

/// Extract the source text covered by a span.
pub fn text(source: String, span: Span) -> String {
  slice(bit_array.from_string(source), span.start, span.end - span.start)
}
