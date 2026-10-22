//// Making code that is being typed compile, so the language server can
//// answer completion, signature help and hover requests while the buffer is
//// incomplete.
////
//// `gleam lsp` only understands code that Bea managed to compile. While you
//// type, the buffer is almost never valid: `timestamp.` has no field name,
//// `add(ts, ` has no closing parenthesis, the argument you are writing has no
//// trailing comma yet. Instead of giving up, the server compiles a repaired
//// copy of the buffer: a placeholder name at the cursor, the brackets that
//// are open at the cursor closed, and (if needed) the rest of the current
//// definition dropped. Everything before the cursor is kept exactly, so
//// positions up to the cursor are the same in the copy and in the buffer.

import gleam/bit_array
import gleam/list
import gleam/string

pub type Bracket {
  Paren
  Square
  Brace
  BitArray
  /// `#{` inside a string
  Interpolation
}

pub type Scan {
  Scan(
    /// Brackets open at the end of the scanned text, innermost first.
    open: List(Bracket),
    in_string: Bool,
    in_comment: Bool,
  )
}

/// Scan source text, tracking open brackets, strings and comments.
pub fn scan(text: String) -> Scan {
  code(bit_array.from_string(text), [])
}

fn code(bits: BitArray, open: List(Bracket)) -> Scan {
  case bits {
    <<>> -> Scan(open, False, False)
    <<"//", rest:bytes>> -> comment(rest, open)
    <<"\"", rest:bytes>> -> in_string(rest, open)
    <<"<<", rest:bytes>> -> code(rest, [BitArray, ..open])
    <<">>", rest:bytes>> ->
      case open {
        [BitArray, ..outer] -> code(rest, outer)
        _ -> code(rest, open)
      }
    <<"(", rest:bytes>> -> code(rest, [Paren, ..open])
    <<"[", rest:bytes>> -> code(rest, [Square, ..open])
    <<"{", rest:bytes>> -> code(rest, [Brace, ..open])
    <<")", rest:bytes>> -> code(rest, pop(open, Paren))
    <<"]", rest:bytes>> -> code(rest, pop(open, Square))
    <<"}", rest:bytes>> ->
      case open {
        [Interpolation, ..outer] -> in_string(rest, outer)
        _ -> code(rest, pop(open, Brace))
      }
    <<_, rest:bytes>> -> code(rest, open)
    _ -> Scan(open, False, False)
  }
}

fn comment(bits: BitArray, open: List(Bracket)) -> Scan {
  case bits {
    <<>> -> Scan(open, False, True)
    <<"\n", rest:bytes>> -> code(rest, open)
    <<_, rest:bytes>> -> comment(rest, open)
    _ -> Scan(open, False, True)
  }
}

fn in_string(bits: BitArray, open: List(Bracket)) -> Scan {
  case bits {
    <<>> -> Scan(open, True, False)
    <<"\\", _, rest:bytes>> -> in_string(rest, open)
    <<"\"", rest:bytes>> -> code(rest, open)
    <<"#{", rest:bytes>> -> code(rest, [Interpolation, ..open])
    <<_, rest:bytes>> -> in_string(rest, open)
    _ -> Scan(open, True, False)
  }
}

/// Close the innermost bracket if it is the expected one. Mismatched
/// closers are ignored: the code is broken anyway, and keeping the outer
/// brackets open gives better repairs.
fn pop(open: List(Bracket), expected: Bracket) -> List(Bracket) {
  case open {
    [b, ..rest] if b == expected -> rest
    _ -> open
  }
}

fn closer(b: Bracket) -> String {
  case b {
    Paren -> ")"
    Square -> "]"
    Brace -> "}"
    BitArray -> ">>"
    Interpolation -> "}\""
  }
}

/// Brackets open at `offset`, innermost first, with the offset of each.
pub fn open_at(text: String, offset: Int) -> List(#(Bracket, Int)) {
  positions(bit_array.from_string(slice(text, 0, offset)), 0, [], False)
}

fn positions(
  bits: BitArray,
  at: Int,
  open: List(#(Bracket, Int)),
  in_str: Bool,
) -> List(#(Bracket, Int)) {
  case in_str, bits {
    _, <<>> -> open
    True, <<"\\", _, rest:bytes>> -> positions(rest, at + 2, open, True)
    True, <<"\"", rest:bytes>> -> positions(rest, at + 1, open, False)
    True, <<"#{", rest:bytes>> ->
      positions(rest, at + 2, [#(Interpolation, at), ..open], False)
    True, <<_, rest:bytes>> -> positions(rest, at + 1, open, True)
    False, <<"//", rest:bytes>> -> {
      let #(rest, skipped) = skip_line(rest, 0)
      positions(rest, at + 2 + skipped, open, False)
    }
    False, <<"\"", rest:bytes>> -> positions(rest, at + 1, open, True)
    False, <<"<<", rest:bytes>> ->
      positions(rest, at + 2, [#(BitArray, at), ..open], False)
    False, <<">>", rest:bytes>> ->
      case open {
        [#(BitArray, _), ..outer] -> positions(rest, at + 2, outer, False)
        _ -> positions(rest, at + 2, open, False)
      }
    False, <<"(", rest:bytes>> ->
      positions(rest, at + 1, [#(Paren, at), ..open], False)
    False, <<"[", rest:bytes>> ->
      positions(rest, at + 1, [#(Square, at), ..open], False)
    False, <<"{", rest:bytes>> ->
      positions(rest, at + 1, [#(Brace, at), ..open], False)
    False, <<")", rest:bytes>> ->
      positions(rest, at + 1, pop_at(open, Paren), False)
    False, <<"]", rest:bytes>> ->
      positions(rest, at + 1, pop_at(open, Square), False)
    False, <<"}", rest:bytes>> ->
      case open {
        [#(Interpolation, _), ..outer] -> positions(rest, at + 1, outer, True)
        _ -> positions(rest, at + 1, pop_at(open, Brace), False)
      }
    False, <<_, rest:bytes>> -> positions(rest, at + 1, open, False)
    _, _ -> open
  }
}

fn skip_line(bits: BitArray, n: Int) -> #(BitArray, Int) {
  case bits {
    <<"\n", _:bytes>> | <<>> -> #(bits, n)
    <<_, rest:bytes>> -> skip_line(rest, n + 1)
    _ -> #(bits, n)
  }
}

fn pop_at(
  open: List(#(Bracket, Int)),
  expected: Bracket,
) -> List(#(Bracket, Int)) {
  case open {
    [#(b, _), ..rest] if b == expected -> rest
    _ -> open
  }
}

pub type Call {
  Call(
    /// Span of the called name (`timestamp.add` -> `add`).
    name_start: Int,
    name_end: Int,
    qualifier: Result(String, Nil),
    name: String,
    /// Index of the argument the cursor is in, counting a piped value.
    argument: Int,
    /// The label of that argument, if it has one (`to: |`).
    label: Result(String, Nil),
  )
}

/// The call whose argument list the cursor is in: `f(a, |` or
/// `x |> mod.f(|`. Stops at the body of an anonymous function.
pub fn call_at(text: String, offset: Int) -> Result(Call, Nil) {
  open_at(text, offset)
  |> find_call(text, offset)
}

fn find_call(
  open: List(#(Bracket, Int)),
  text: String,
  offset: Int,
) -> Result(Call, Nil) {
  case open {
    [] -> Error(Nil)
    [#(Brace, _), ..] | [#(Interpolation, _), ..] -> Error(Nil)
    [#(Paren, at), ..outer] -> {
      let name_start = word_start(text, at)
      case name_start < at {
        // `(a, b)` is a tuple or a grouping, not a call.
        False -> find_call(outer, text, offset)
        True -> {
          let #(qualifier, name, start, end) =
            qualified_name_at(text, name_start)
          // `fn(x|`: parameters of an anonymous function, not a call; show
          // the call it is an argument of.
          use <- bool_guard(name == "fn" && qualifier == Error(Nil), fn() {
            find_call(outer, text, offset)
          })
          let args = slice(text, at + 1, offset)
          let parts = top_level_commas(args)
          let current = list.last(parts) |> result_unwrap("")
          let label = case string.split_once(current, ":") {
            Ok(#(l, _)) ->
              case string.trim(l) {
                "" -> Error(Nil)
                l ->
                  case word_end(l, 0) == string.byte_size(l) {
                    True -> Ok(l)
                    False -> Error(Nil)
                  }
              }
            Error(_) -> Error(Nil)
          }
          let callee_start = case qualifier {
            Ok(q) -> start - 1 - string.byte_size(q)
            Error(_) -> start
          }
          let piped =
            string.ends_with(
              string.trim_end(slice(text, 0, callee_start)),
              "|>",
            )
          let argument =
            list.length(parts)
            - 1
            + case piped {
              True -> 1
              False -> 0
            }
          Ok(Call(start, end, qualifier, name, argument, label))
        }
      }
    }
    [_, ..outer] -> find_call(outer, text, offset)
  }
}

fn bool_guard(
  stop: Bool,
  otherwise: fn() -> Result(Call, Nil),
  next: fn() -> Result(Call, Nil),
) -> Result(Call, Nil) {
  case stop {
    True -> otherwise()
    False -> next()
  }
}

fn result_unwrap(r: Result(a, Nil), default: a) -> a {
  case r {
    Ok(x) -> x
    Error(_) -> default
  }
}

/// Split argument text on commas outside of brackets and strings (there is
/// always at least one, possibly empty, part).
fn top_level_commas(args: String) -> List(String) {
  split_commas(bit_array.from_string(args), 0, False, <<>>, [])
}

fn split_commas(
  bits: BitArray,
  depth: Int,
  in_str: Bool,
  current: BitArray,
  acc: List(String),
) -> List(String) {
  let flush = fn() {
    case bit_array.to_string(current) {
      Ok(s) -> s
      Error(_) -> ""
    }
  }
  case in_str, bits {
    _, <<>> -> list.reverse([flush(), ..acc])
    True, <<"\\", c, rest:bytes>> ->
      split_commas(rest, depth, True, <<current:bits, "\\", c>>, acc)
    True, <<"\"", rest:bytes>> ->
      split_commas(rest, depth, False, <<current:bits, "\"">>, acc)
    True, <<c, rest:bytes>> ->
      split_commas(rest, depth, True, <<current:bits, c>>, acc)
    False, <<"\"", rest:bytes>> ->
      split_commas(rest, depth, True, <<current:bits, "\"">>, acc)
    False, <<"//", rest:bytes>> -> {
      // Comments don't count, up to the end of their line.
      let #(rest, _) = skip_line(rest, 0)
      split_commas(rest, depth, False, current, acc)
    }
    False, <<"<<", rest:bytes>> ->
      split_commas(rest, depth + 1, False, <<current:bits, "<<">>, acc)
    False, <<">>", rest:bytes>> ->
      split_commas(rest, depth - 1, False, <<current:bits, ">>">>, acc)
    False, <<",", rest:bytes>> if depth == 0 ->
      split_commas(rest, depth, False, <<>>, [flush(), ..acc])
    False, <<c, rest:bytes>> ->
      case c {
        40 | 91 | 123 ->
          split_commas(rest, depth + 1, False, <<current:bits, c>>, acc)
        41 | 93 | 125 ->
          split_commas(rest, depth - 1, False, <<current:bits, c>>, acc)
        _ -> split_commas(rest, depth, False, <<current:bits, c>>, acc)
      }
    _, _ -> list.reverse([flush(), ..acc])
  }
}

/// Is the offset inside a string or a comment (where there is nothing to
/// complete)?
pub fn in_text(text: String, offset: Int) -> Bool {
  let s = scan(slice(text, 0, offset))
  s.in_comment || { s.in_string && !list.contains(s.open, Interpolation) }
}

/// Repaired versions of `text`, with `hole` inserted at `offset`, from the
/// least to the most invasive. The caller compiles them in order and uses the
/// first one that compiles.
pub fn candidates(text: String, offset: Int, hole: String) -> List(String) {
  let size = string.byte_size(text)
  let prefix = slice(text, 0, offset) <> hole
  let suffix = slice(text, offset, size)
  let s = scan(slice(text, 0, offset))
  let rest = slice(text, next_item(text, offset), size)
  let closers = list.map(s.open, closer)
  let in_args = case s.open {
    [Paren, ..] | [Square, ..] -> True
    _ -> False
  }
  // `outer(inner(a, |\n  b: 1)`: close the inner call(s) only and keep the
  // rest, separated by a comma when it continues an argument list.
  let partial =
    list.index_map(s.open, fn(_, i) { i + 1 })
    |> list.filter(fn(k) { k < list.length(s.open) })
    |> list.flat_map(fn(k) {
      let closed = string.concat(list.take(closers, k))
      case list.drop(s.open, k) {
        [Paren, ..] | [Square, ..] -> [
          prefix <> closed <> ", " <> suffix,
          prefix <> closed <> suffix,
        ]
        _ -> [prefix <> closed <> suffix]
      }
    })
  [
    // `f(a, |)`, `x.|` followed by valid code, ...
    [prefix <> suffix],
    // `Ctor(\n  a.|\n  b: 1,\n)`: the argument being written has no comma yet.
    case in_args {
      True -> [prefix <> ", " <> suffix]
      False -> []
    },
    partial,
    // Close what is open and drop the rest of the current definition.
    [
      prefix <> "\n" <> string.join(closers, "\n") <> "\n\n" <> rest,
      prefix <> string.concat(closers) <> "\n\n" <> rest,
    ],
    // ... and of the file, in case something later is broken too.
    [prefix <> "\n" <> string.join(closers, "\n") <> "\n"],
  ]
  |> list.flatten
  |> list.unique
}

/// Start of the next top-level item after `offset`: the first line that
/// starts in column 0 with something other than a closing bracket.
pub fn next_item(text: String, offset: Int) -> Int {
  let bits = bit_array.from_string(text)
  let size = bit_array.byte_size(bits)
  case bit_array.slice(bits, offset, size - offset) {
    Ok(rest) -> find_item(rest, offset, False)
    Error(_) -> size
  }
}

fn find_item(bits: BitArray, offset: Int, at_line_start: Bool) -> Int {
  case bits {
    <<>> -> offset
    <<"\n", rest:bytes>> -> find_item(rest, offset + 1, True)
    <<c, rest:bytes>> if at_line_start ->
      case c {
        32 | 9 | 13 | 41 | 93 | 125 -> find_item(rest, offset + 1, False)
        _ -> offset
      }
    <<_, rest:bytes>> -> find_item(rest, offset + 1, False)
    _ -> offset
  }
}

/// Bytes `[from, to)` of a string.
pub fn slice(text: String, from: Int, to: Int) -> String {
  let bits = bit_array.from_string(text)
  let size = bit_array.byte_size(bits)
  let from = clamp(from, 0, size)
  let to = clamp(to, from, size)
  case bit_array.slice(bits, from, to - from) {
    Ok(part) ->
      case bit_array.to_string(part) {
        Ok(s) -> s
        Error(_) -> ""
      }
    Error(_) -> ""
  }
}

fn clamp(x: Int, low: Int, high: Int) -> Int {
  case x < low, x > high {
    True, _ -> low
    _, True -> high
    _, _ -> x
  }
}

// --- Words around the cursor ---------------------------------------------------------

fn is_name_byte(c: Int) -> Bool {
  { c >= 97 && c <= 122 }
  || { c >= 65 && c <= 90 }
  || { c >= 48 && c <= 57 }
  || c == 95
}

/// Start of the name that ends at `offset` (`offset` itself when there is
/// none).
pub fn word_start(text: String, offset: Int) -> Int {
  let bits = bit_array.from_string(text)
  back(bits, offset)
}

fn back(bits: BitArray, offset: Int) -> Int {
  case offset > 0 {
    False -> 0
    True ->
      case bit_array.slice(bits, offset - 1, 1) {
        Ok(<<c>>) ->
          case is_name_byte(c) {
            True -> back(bits, offset - 1)
            False -> offset
          }
        _ -> offset
      }
  }
}

/// End of the name that starts before or at `offset`.
pub fn word_end(text: String, offset: Int) -> Int {
  let bits = bit_array.from_string(text)
  forward(bits, offset, bit_array.byte_size(bits))
}

fn forward(bits: BitArray, offset: Int, size: Int) -> Int {
  case offset < size {
    False -> size
    True ->
      case bit_array.slice(bits, offset, 1) {
        Ok(<<c>>) ->
          case is_name_byte(c) {
            True -> forward(bits, offset + 1, size)
            False -> offset
          }
        _ -> offset
      }
  }
}

/// The byte just before `offset`, as a string ("" at the start).
pub fn char_before(text: String, offset: Int) -> String {
  slice(text, offset - 1, offset)
}

/// The byte at `offset`, as a string ("" at the end).
pub fn char_at(text: String, offset: Int) -> String {
  slice(text, offset, offset + 1)
}

/// The name under the cursor and the module qualifier in front of it, if
/// any: `timestamp.ad|d` -> #(Some("timestamp"), "add", start, end).
pub fn qualified_name_at(
  text: String,
  offset: Int,
) -> #(Result(String, Nil), String, Int, Int) {
  let start = word_start(text, offset)
  let end = word_end(text, offset)
  let name = slice(text, start, end)
  let qualifier = case char_before(text, start) {
    "." -> {
      let q_start = word_start(text, start - 1)
      case q_start < start - 1 {
        True -> Ok(slice(text, q_start, start - 1))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
  #(qualifier, name, start, end)
}

/// The text before `offset` on the same line, without leading spaces.
pub fn line_before(text: String, offset: Int) -> String {
  let before = slice(text, 0, offset)
  case string.split(before, "\n") |> list.last {
    Ok(line) -> string.trim_start(line)
    Error(_) -> ""
  }
}
