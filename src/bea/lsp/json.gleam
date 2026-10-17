//// A small JSON implementation for the language server.
////
//// LSP messages are mostly forwarded with small edits (URIs and positions),
//// so a generic tree that keeps object key order is the most convenient
//// representation. Parsing works on bytes; strings are kept as UTF-8.

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/string_tree.{type StringTree}

pub type Json {
  Null
  Bool(Bool)
  Int(Int)
  Float(Float)
  String(String)
  Array(List(Json))
  Object(List(#(String, Json)))
}

// --- Access helpers -------------------------------------------------------------

pub fn get(json: Json, key: String) -> Option(Json) {
  case json {
    Object(fields) -> list.key_find(fields, key) |> option.from_result
    _ -> None
  }
}

/// Follow a path of keys.
pub fn at(json: Json, path: List(String)) -> Option(Json) {
  case path {
    [] -> Some(json)
    [key, ..rest] ->
      case get(json, key) {
        Some(j) -> at(j, rest)
        None -> None
      }
  }
}

pub fn string_at(json: Json, path: List(String)) -> Option(String) {
  case at(json, path) {
    Some(String(s)) -> Some(s)
    _ -> None
  }
}

pub fn int_at(json: Json, path: List(String)) -> Option(Int) {
  case at(json, path) {
    Some(Int(i)) -> Some(i)
    Some(Float(f)) -> Some(float.truncate(f))
    _ -> None
  }
}

pub fn set(json: Json, key: String, value: Json) -> Json {
  case json {
    Object(fields) ->
      case list.key_find(fields, key) {
        Ok(_) ->
          Object(
            list.map(fields, fn(f) {
              case f.0 == key {
                True -> #(key, value)
                False -> f
              }
            }),
          )
        Error(_) -> Object(list.append(fields, [#(key, value)]))
      }
    _ -> json
  }
}

/// Update a nested value if present.
pub fn update_at(json: Json, path: List(String), f: fn(Json) -> Json) -> Json {
  case path {
    [] -> f(json)
    [key, ..rest] ->
      case get(json, key) {
        Some(inner) -> set(json, key, update_at(inner, rest, f))
        None -> json
      }
  }
}

pub fn object(fields: List(#(String, Json))) -> Json {
  Object(fields)
}

pub fn nullable(o: Option(a), f: fn(a) -> Json) -> Json {
  case o {
    Some(x) -> f(x)
    None -> Null
  }
}

// --- Encoding -------------------------------------------------------------------

pub fn to_string(json: Json) -> String {
  encode(json, string_tree.new()) |> string_tree.to_string
}

fn encode(json: Json, acc: StringTree) -> StringTree {
  case json {
    Null -> string_tree.append(acc, "null")
    Bool(True) -> string_tree.append(acc, "true")
    Bool(False) -> string_tree.append(acc, "false")
    Int(i) -> string_tree.append(acc, int.to_string(i))
    Float(f) -> string_tree.append(acc, float.to_string(f))
    String(s) -> encode_string(s, acc)
    Array(items) -> {
      let acc = string_tree.append(acc, "[")
      let acc =
        list.index_fold(items, acc, fn(acc, item, i) {
          let acc = case i {
            0 -> acc
            _ -> string_tree.append(acc, ",")
          }
          encode(item, acc)
        })
      string_tree.append(acc, "]")
    }
    Object(fields) -> {
      let acc = string_tree.append(acc, "{")
      let acc =
        list.index_fold(fields, acc, fn(acc, field, i) {
          let acc = case i {
            0 -> acc
            _ -> string_tree.append(acc, ",")
          }
          let acc = encode_string(field.0, acc)
          let acc = string_tree.append(acc, ":")
          encode(field.1, acc)
        })
      string_tree.append(acc, "}")
    }
  }
}

fn encode_string(s: String, acc: StringTree) -> StringTree {
  let escaped = case needs_escape(bit_array.from_string(s)) {
    False -> s
    True ->
      s
      |> string.to_utf_codepoints
      |> list.map(fn(cp) {
        case string.utf_codepoint_to_int(cp) {
          0x22 -> "\\\""
          0x5C -> "\\\\"
          0x0A -> "\\n"
          0x0D -> "\\r"
          0x09 -> "\\t"
          0x08 -> "\\b"
          0x0C -> "\\f"
          c if c < 0x20 -> "\\u" <> string.pad_start(int.to_base16(c), 4, "0")
          _ -> string.from_utf_codepoints([cp])
        }
      })
      |> string.concat
  }
  acc
  |> string_tree.append("\"")
  |> string_tree.append(escaped)
  |> string_tree.append("\"")
}

fn needs_escape(bits: BitArray) -> Bool {
  case bits {
    <<c, rest:bytes>> ->
      case c < 0x20 || c == 0x22 || c == 0x5C {
        True -> True
        False -> needs_escape(rest)
      }
    _ -> False
  }
}

// --- Parsing --------------------------------------------------------------------

pub fn parse(text: String) -> Result(Json, Nil) {
  parse_bits(bit_array.from_string(text))
}

pub fn parse_bits(bits: BitArray) -> Result(Json, Nil) {
  use #(value, rest) <- result.try(value(skip_ws(bits)))
  case skip_ws(rest) {
    <<>> -> Ok(value)
    _ -> Error(Nil)
  }
}

fn skip_ws(bits: BitArray) -> BitArray {
  case bits {
    <<" ", rest:bytes>>
    | <<"\n", rest:bytes>>
    | <<"\r", rest:bytes>>
    | <<"\t", rest:bytes>> -> skip_ws(rest)
    _ -> bits
  }
}

fn value(bits: BitArray) -> Result(#(Json, BitArray), Nil) {
  case bits {
    <<"null", rest:bytes>> -> Ok(#(Null, rest))
    <<"true", rest:bytes>> -> Ok(#(Bool(True), rest))
    <<"false", rest:bytes>> -> Ok(#(Bool(False), rest))
    <<"\"", rest:bytes>> -> {
      use #(s, rest) <- result.try(string_body(rest, []))
      Ok(#(String(s), rest))
    }
    <<"[", rest:bytes>> -> array(skip_ws(rest), [])
    <<"{", rest:bytes>> -> object_(skip_ws(rest), [])
    <<c, _:bytes>> if c == 45 || { c >= 48 && c <= 57 } -> number(bits)
    _ -> Error(Nil)
  }
}

fn array(bits: BitArray, acc: List(Json)) -> Result(#(Json, BitArray), Nil) {
  case bits {
    <<"]", rest:bytes>> if acc == [] -> Ok(#(Array([]), rest))
    _ -> {
      use #(item, rest) <- result.try(value(skip_ws(bits)))
      case skip_ws(rest) {
        <<",", rest:bytes>> -> array(skip_ws(rest), [item, ..acc])
        <<"]", rest:bytes>> -> Ok(#(Array(list.reverse([item, ..acc])), rest))
        _ -> Error(Nil)
      }
    }
  }
}

fn object_(
  bits: BitArray,
  acc: List(#(String, Json)),
) -> Result(#(Json, BitArray), Nil) {
  case bits {
    <<"}", rest:bytes>> if acc == [] -> Ok(#(Object([]), rest))
    <<"\"", rest:bytes>> -> {
      use #(key, rest) <- result.try(string_body(rest, []))
      case skip_ws(rest) {
        <<":", rest:bytes>> -> {
          use #(v, rest) <- result.try(value(skip_ws(rest)))
          case skip_ws(rest) {
            <<",", rest:bytes>> -> object_(skip_ws(rest), [#(key, v), ..acc])
            <<"}", rest:bytes>> ->
              Ok(#(Object(list.reverse([#(key, v), ..acc])), rest))
            _ -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// Parses a string body after the opening quote. Plain runs of bytes are
/// collected as slices for speed.
fn string_body(
  bits: BitArray,
  acc: List(BitArray),
) -> Result(#(String, BitArray), Nil) {
  let run = plain_run(bits, 0)
  let assert Ok(chunk) = bit_array.slice(bits, 0, run)
  let rest = drop(bits, run)
  let acc = [chunk, ..acc]
  case rest {
    <<"\"", rest:bytes>> -> {
      let joined = bit_array.concat(list.reverse(acc))
      case bit_array.to_string(joined) {
        Ok(s) -> Ok(#(s, rest))
        Error(_) -> Error(Nil)
      }
    }
    <<"\\", c, rest:bytes>> ->
      case c {
        0x22 -> string_body(rest, [<<"\"">>, ..acc])
        0x5C -> string_body(rest, [<<"\\">>, ..acc])
        0x2F -> string_body(rest, [<<"/">>, ..acc])
        0x62 -> string_body(rest, [<<8>>, ..acc])
        0x66 -> string_body(rest, [<<12>>, ..acc])
        0x6E -> string_body(rest, [<<"\n">>, ..acc])
        0x72 -> string_body(rest, [<<"\r">>, ..acc])
        0x74 -> string_body(rest, [<<"\t">>, ..acc])
        0x75 -> {
          use #(code, rest) <- result.try(hex4(rest))
          // Surrogate pairs encode characters outside the BMP.
          case code >= 0xD800 && code <= 0xDBFF, rest {
            True, <<"\\u", more:bytes>> -> {
              use #(low, rest) <- result.try(hex4(more))
              let combined =
                0x10000 + { code - 0xD800 } * 0x400 + { low - 0xDC00 }
              string_body(rest, [codepoint(combined), ..acc])
            }
            _, _ -> string_body(rest, [codepoint(code), ..acc])
          }
        }
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn codepoint(code: Int) -> BitArray {
  case string.utf_codepoint(code) {
    Ok(cp) -> bit_array.from_string(string.from_utf_codepoints([cp]))
    Error(_) -> <<"\u{FFFD}":utf8>>
  }
}

fn plain_run(bits: BitArray, n: Int) -> Int {
  case bits {
    <<"\"", _:bytes>> | <<"\\", _:bytes>> -> n
    <<_, rest:bytes>> -> plain_run(rest, n + 1)
    _ -> n
  }
}

fn hex4(bits: BitArray) -> Result(#(Int, BitArray), Nil) {
  case bits {
    <<a, b, c, d, rest:bytes>> -> {
      let assert Ok(s) = bit_array.to_string(<<a, b, c, d>>)
      case int.base_parse(s, 16) {
        Ok(n) -> Ok(#(n, rest))
        Error(_) -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn number(bits: BitArray) -> Result(#(Json, BitArray), Nil) {
  let len = number_length(bits, 0, False)
  let assert Ok(chunk) = bit_array.slice(bits, 0, len)
  let rest = drop(bits, len)
  let assert Ok(text) = bit_array.to_string(chunk)
  case int.parse(text) {
    Ok(i) -> Ok(#(Int(i), rest))
    Error(_) ->
      case float.parse(normalise_float(text)) {
        Ok(f) -> Ok(#(Float(f), rest))
        Error(_) -> Error(Nil)
      }
  }
}

/// Gleam's float parser wants a fractional part: `1e5` -> `1.0e5`.
fn normalise_float(text: String) -> String {
  case string.contains(text, ".") {
    True -> text
    False ->
      case string.split_once(string.lowercase(text), "e") {
        Ok(#(mantissa, exp)) -> mantissa <> ".0e" <> exp
        Error(_) -> text <> ".0"
      }
  }
}

fn number_length(bits: BitArray, n: Int, _seen: Bool) -> Int {
  case bits {
    <<c, rest:bytes>>
      if { c >= 48 && c <= 57 }
      || c == 45
      || c == 43
      || c == 46
      || c == 101
      || c == 69
    -> number_length(rest, n + 1, True)
    _ -> n
  }
}

fn drop(bits: BitArray, n: Int) -> BitArray {
  case bit_array.slice(bits, n, bit_array.byte_size(bits) - n) {
    Ok(b) -> b
    Error(_) -> <<>>
  }
}
