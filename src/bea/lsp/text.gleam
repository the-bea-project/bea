//// Bracket-aware string helpers for reading declaration headers and
//// signature labels: split `a: List(#(a, b)), b: fn(a) -> b` on its top-level
//// commas, find the parenthesis that closes a parameter list, ...

import gleam/list
import gleam/string

/// Depth of brackets at the end of `s`, which starts just after an opening
/// bracket; -1 as soon as that bracket is closed.
pub fn depth_after(s: String) -> Int {
  walk(string.to_graphemes(s), 0, False)
}

fn walk(cs: List(String), depth: Int, in_string: Bool) -> Int {
  case cs, in_string {
    [], _ -> depth
    ["\\", _, ..rest], True -> walk(rest, depth, True)
    ["\"", ..rest], _ -> walk(rest, depth, !in_string)
    [_, ..rest], True -> walk(rest, depth, True)
    [c, ..rest], False ->
      case c {
        "(" | "[" | "{" -> walk(rest, depth + 1, False)
        ")" | "]" | "}" ->
          case depth {
            0 -> -1
            _ -> walk(rest, depth - 1, False)
          }
        _ -> walk(rest, depth, False)
      }
  }
}

/// Split `s` (which starts just after an opening bracket) at the bracket
/// that closes it: `#(inside, after)`.
pub fn split_at_close(s: String) -> #(String, String) {
  close(string.to_graphemes(s), 0, False, [])
}

fn close(
  cs: List(String),
  depth: Int,
  in_string: Bool,
  acc: List(String),
) -> #(String, String) {
  case cs, in_string {
    [], _ -> #(string.concat(list.reverse(acc)), "")
    ["\\", c, ..rest], True -> close(rest, depth, True, [c, "\\", ..acc])
    ["\"", ..rest], _ -> close(rest, depth, !in_string, ["\"", ..acc])
    [c, ..rest], True -> close(rest, depth, True, [c, ..acc])
    [c, ..rest], False ->
      case c {
        "(" | "[" | "{" -> close(rest, depth + 1, False, [c, ..acc])
        ")" | "]" | "}" ->
          case depth {
            0 -> #(string.concat(list.reverse(acc)), string.concat(rest))
            _ -> close(rest, depth - 1, False, [c, ..acc])
          }
        _ -> close(rest, depth, False, [c, ..acc])
      }
  }
}

/// Split on `separator` (one character) outside of brackets and strings.
pub fn split_top_level(s: String, separator: String) -> List(String) {
  split(string.to_graphemes(s), separator, 0, False, [], [])
}

fn split(
  cs: List(String),
  sep: String,
  depth: Int,
  in_string: Bool,
  current: List(String),
  acc: List(String),
) -> List(String) {
  let flush = fn() { string.concat(list.reverse(current)) }
  case cs, in_string {
    [], _ ->
      case current, acc {
        [], [] -> []
        _, _ -> list.reverse([flush(), ..acc])
      }
    ["\\", c, ..rest], True ->
      split(rest, sep, depth, True, [c, "\\", ..current], acc)
    ["\"", ..rest], _ ->
      split(rest, sep, depth, !in_string, ["\"", ..current], acc)
    [c, ..rest], True -> split(rest, sep, depth, True, [c, ..current], acc)
    [c, ..rest], False ->
      case c {
        _ if c == sep && depth == 0 ->
          split(rest, sep, depth, False, [], [flush(), ..acc])
        "(" | "[" | "{" ->
          split(rest, sep, depth + 1, False, [c, ..current], acc)
        ")" | "]" | "}" ->
          split(rest, sep, int_max(depth - 1, 0), False, [c, ..current], acc)
        _ -> split(rest, sep, depth, False, [c, ..current], acc)
      }
  }
}

fn int_max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

/// The text before the first top-level `stop` character.
pub fn until_top_level(s: String, stop: String) -> String {
  case split_top_level(s, stop) {
    [first, ..] -> first
    [] -> ""
  }
}
