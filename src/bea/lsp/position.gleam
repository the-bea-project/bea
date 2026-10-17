//// Conversions between LSP positions/URIs and Bea's byte offsets/paths.

import bea/lsp/json.{type Json}
import bea/span.{type LineIndex, type Span, Position, Span}
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub fn uri_to_path(uri: String) -> Option(String) {
  case uri {
    "file://" <> rest -> {
      let path = percent_decode(rest)
      // `file:///c:/x` on Windows.
      let path = case string.to_graphemes(path) {
        ["/", drive, ":", ..more] ->
          case
            string.contains(
              "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ",
              drive,
            )
          {
            True -> drive <> ":" <> string.concat(more)
            False -> path
          }
        _ -> path
      }
      Some(path)
    }
    _ -> None
  }
}

pub fn path_to_uri(path: String) -> String {
  let path = case string.starts_with(path, "/") {
    True -> path
    False -> "/" <> path
  }
  "file://" <> percent_encode(path)
}

fn percent_decode(s: String) -> String {
  case string.contains(s, "%") {
    False -> s
    True -> {
      let bytes = decode_bytes(bit_array.from_string(s), <<>>)
      case bit_array.to_string(bytes) {
        Ok(decoded) -> decoded
        Error(_) -> s
      }
    }
  }
}

fn decode_bytes(bits: BitArray, acc: BitArray) -> BitArray {
  case bits {
    <<"%", a, b, rest:bytes>> -> {
      let assert Ok(hex) = bit_array.to_string(<<a, b>>)
      case int.base_parse(hex, 16) {
        Ok(n) -> decode_bytes(rest, <<acc:bits, n>>)
        Error(_) -> decode_bytes(rest, <<acc:bits, "%":utf8, a, b>>)
      }
    }
    <<c, rest:bytes>> -> decode_bytes(rest, <<acc:bits, c>>)
    _ -> acc
  }
}

fn percent_encode(s: String) -> String {
  encode_bytes(bit_array.from_string(s), [])
}

fn encode_bytes(bits: BitArray, acc: List(String)) -> String {
  case bits {
    <<c, rest:bytes>> -> {
      let keep =
        { c >= 97 && c <= 122 }
        || { c >= 65 && c <= 90 }
        || { c >= 48 && c <= 57 }
        || c == 45
        || c == 46
        || c == 95
        || c == 126
        || c == 47
      let piece = case keep {
        True -> {
          let assert Ok(ch) = bit_array.to_string(<<c>>)
          ch
        }
        False -> "%" <> string.pad_start(int.to_base16(c), 2, "0")
      }
      encode_bytes(rest, [piece, ..acc])
    }
    _ -> string.concat(list.reverse(acc))
  }
}

pub fn to_offset(index: LineIndex, position: Json) -> Int {
  let line = json.int_at(position, ["line"]) |> option.unwrap(0)
  let character = json.int_at(position, ["character"]) |> option.unwrap(0)
  span.utf16_offset(index, Position(line, character))
}

pub fn from_offset(index: LineIndex, offset: Int) -> Json {
  let Position(line, character) = span.utf16_position(index, offset)
  json.object([#("line", json.Int(line)), #("character", json.Int(character))])
}

pub fn range_to_span(index: LineIndex, range: Json) -> Span {
  let start = case json.get(range, "start") {
    Some(p) -> to_offset(index, p)
    None -> 0
  }
  let end = case json.get(range, "end") {
    Some(p) -> to_offset(index, p)
    None -> start
  }
  Span(start, end)
}

pub fn span_to_range(index: LineIndex, s: Span) -> Json {
  json.object([
    #("start", from_offset(index, s.start)),
    #("end", from_offset(index, s.end)),
  ])
}
