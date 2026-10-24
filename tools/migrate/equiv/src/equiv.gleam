//// Are two Gleam source trees the same program?
////
//// Used while migrating the compiler to Bea: the original Gleam modules are
//// compared with the Gleam that the trusted compiler generates from their
//// Bea translations. Both trees are parsed with `glance` and compared
//// definition by definition, with positions erased and a few differences
//// that don't change the program normalised away:
////
//// - comments (glance doesn't keep them; Bea forwards doc comments only),
//// - layout (the trees are compared, not the text),
//// - label shorthand: `f(x:)` is `f(x: x)`, `Ctor(x:)` binds `x`,
//// - `let` versus `let assert` for a pattern that can't fail: Bea writes
////   `let assert` when it can't prove a pattern irrefutable. This one is
////   reported separately ("soft") so every case can be looked at.
////
//// Usage: gleam run -- ORIGINAL_DIR GENERATED_DIR
//// Exit status: 0 when every module is equivalent (soft differences
//// allowed), 1 otherwise.

import argv
import glance
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/regexp
import gleam/string
import simplifile

pub fn main() -> Nil {
  case argv.load().arguments {
    [original, generated] -> halt(run(original, generated))
    _ -> {
      io.println_error("usage: gleam run -- ORIGINAL_DIR GENERATED_DIR")
      halt(2)
    }
  }
}

@external(erlang, "erlang", "halt")
fn halt(code: Int) -> Nil

type Outcome {
  Same
  Soft(List(String))
  Different(List(String))
}

fn run(original: String, generated: String) -> Int {
  let modules =
    list.append(gleam_files(original), gleam_files(generated))
    |> list.unique
    |> list.sort(string.compare)
  let outcomes =
    list.map(modules, fn(module) {
      let outcome =
        compare_files(original <> "/" <> module, generated <> "/" <> module)
      case outcome {
        Same -> io.println("same      " <> module)
        Soft(notes) -> {
          io.println("soft      " <> module)
          list.each(notes, fn(n) { io.println("    " <> n) })
        }
        Different(notes) -> {
          io.println("DIFFERENT " <> module)
          list.each(notes, fn(n) { io.println("    " <> n) })
        }
      }
      outcome
    })
  let different =
    list.count(outcomes, fn(o) {
      case o {
        Different(_) -> True
        _ -> False
      }
    })
  let soft =
    list.count(outcomes, fn(o) {
      case o {
        Soft(_) -> True
        _ -> False
      }
    })
  io.println(
    int.to_string(list.length(modules))
    <> " modules: "
    <> int.to_string(list.length(modules) - different - soft)
    <> " same, "
    <> int.to_string(soft)
    <> " soft, "
    <> int.to_string(different)
    <> " different",
  )
  case different {
    0 -> 0
    _ -> 1
  }
}

/// The Gleam modules under `dir`, relative to it.
fn gleam_files(dir: String) -> List(String) {
  let assert Ok(files) = simplifile.get_files(dir)
  files
  |> list.filter(string.ends_with(_, ".gleam"))
  |> list.map(string.drop_start(_, string.length(dir) + 1))
}

fn compare_files(a: String, b: String) -> Outcome {
  case simplifile.read(a), simplifile.read(b) {
    Ok(a), Ok(b) ->
      case glance.module(a), glance.module(b) {
        Ok(a), Ok(b) -> compare(a, b)
        Error(e), _ ->
          Different(["original doesn't parse: " <> string.inspect(e)])
        _, Error(e) ->
          Different(["generated doesn't parse: " <> string.inspect(e)])
      }
    Error(_), _ -> Different(["original missing"])
    _, Error(_) -> Different(["generated missing"])
  }
}

fn compare(a: glance.Module, b: glance.Module) -> Outcome {
  let sections = [
    #("import", keyed(a.imports, import_key), keyed(b.imports, import_key)),
    #(
      "type",
      keyed(a.custom_types, fn(d) { d.definition.name }),
      keyed(b.custom_types, fn(d) { d.definition.name }),
    ),
    #(
      "type alias",
      keyed(a.type_aliases, fn(d) { d.definition.name }),
      keyed(b.type_aliases, fn(d) { d.definition.name }),
    ),
    #(
      "const",
      keyed(a.constants, fn(d) { d.definition.name }),
      keyed(b.constants, fn(d) { d.definition.name }),
    ),
    #(
      "fn",
      keyed(a.functions, fn(d) { d.definition.name }),
      keyed(b.functions, fn(d) { d.definition.name }),
    ),
  ]
  let #(hard, soft) =
    list.fold(sections, #([], []), fn(acc, section) {
      let #(kind, xs, ys) = section
      let names =
        list.append(dict.keys(xs), dict.keys(ys))
        |> list.unique
        |> list.sort(string.compare)
      list.fold(names, acc, fn(acc, name) {
        let #(hard, soft) = acc
        case dict.get(xs, name), dict.get(ys, name) {
          Ok(x), Ok(y) ->
            case x == y, relax(x) == relax(y) {
              True, _ -> acc
              False, True -> #(hard, [
                kind <> " " <> name <> ": let/let assert",
                ..soft
              ])
              False, False -> #(
                [kind <> " " <> name <> ": " <> first_difference(x, y), ..hard],
                soft,
              )
            }
          Ok(_), Error(_) -> #(
            [kind <> " " <> name <> ": only in the original", ..hard],
            soft,
          )
          Error(_), Ok(_) -> #(
            [kind <> " " <> name <> ": only in the generated code", ..hard],
            soft,
          )
          Error(_), Error(_) -> acc
        }
      })
    })
  case hard, soft {
    [], [] -> Same
    [], _ -> Soft(list.reverse(soft))
    _, _ -> Different(list.append(list.reverse(hard), list.reverse(soft)))
  }
}

fn import_key(d: glance.Definition(glance.Import)) -> String {
  d.definition.module
}

/// Definitions by name, as comparable strings.
fn keyed(
  definitions: List(glance.Definition(a)),
  key: fn(glance.Definition(a)) -> String,
) -> dict.Dict(String, String) {
  definitions
  |> list.map(fn(d) { #(key(d), normalise(d)) })
  |> dict.from_list
}

fn normalise(definition: a) -> String {
  let text = string.inspect(definition)
  let text = replace("Span\\(\\d+, \\d+\\)", text, "S")
  // Label shorthand: `x:` is `x: x` in expressions and in patterns, and in
  // record updates `Ctor(..r, x:)` is `Ctor(..r, x: x)`.
  let text =
    replace(
      "LabelledField\\(\"(\\w+)\", S, (Pattern)?Variable\\(S, \"\\1\"\\)\\)",
      text,
      "ShorthandField(\"\\1\", S)",
    )
  let text =
    replace(
      "RecordUpdateField\\(\"(\\w+)\", Some\\(Variable\\(S, \"\\1\"\\)\\)\\)",
      text,
      "RecordUpdateField(\"\\1\", None)",
    )
  unwrap_blocks(text)
}

/// `{ x }` is `x`: a block holding a single expression (no bindings, so no
/// scope) is the expression itself.
fn unwrap_blocks(text: String) -> String {
  let open = "Block(S, [Expression("
  case string.split_once(text, open) {
    Error(_) -> text
    Ok(#(before, after)) -> {
      let #(inner, rest) = until_close(string.to_graphemes(after), 0, False, [])
      case string.starts_with(rest, ")])") {
        True -> before <> unwrap_blocks(inner <> string.drop_start(rest, 3))
        // A block with more statements: keep it, look further.
        False -> before <> "Block(S, [" <> unwrap_blocks("Expression(" <> after)
      }
    }
  }
}

/// Splits after an opening `(` at its matching `)`, skipping string
/// literals of the inspected text.
fn until_close(
  cs: List(String),
  depth: Int,
  in_string: Bool,
  acc: List(String),
) -> #(String, String) {
  case cs, in_string {
    [], _ -> #(string.concat(list.reverse(acc)), "")
    ["\\", c, ..rest], True -> until_close(rest, depth, True, [c, "\\", ..acc])
    ["\"", ..rest], _ -> until_close(rest, depth, !in_string, ["\"", ..acc])
    [c, ..rest], True -> until_close(rest, depth, True, [c, ..acc])
    [")", ..rest], False if depth == 0 -> #(
      string.concat(list.reverse(acc)),
      ")" <> string.concat(rest),
    )
    [")", ..rest], False -> until_close(rest, depth - 1, False, [")", ..acc])
    ["(", ..rest], False -> until_close(rest, depth + 1, False, ["(", ..acc])
    [c, ..rest], False -> until_close(rest, depth, False, [c, ..acc])
  }
}

/// The same with `let assert` (without a message) read as `let`.
fn relax(text: String) -> String {
  replace("LetAssert\\(None\\)", text, "Let")
}

fn replace(pattern: String, text: String, with: String) -> String {
  let assert Ok(re) = regexp.from_string(pattern)
  regexp.replace(re, text, with)
}

/// A little context around the first place two strings differ.
fn first_difference(a: String, b: String) -> String {
  let prefix = common_prefix(string.to_graphemes(a), string.to_graphemes(b), 0)
  let context = fn(s: String) { string.slice(s, int.max(0, prefix - 40), 120) }
  "\n        original:  " <> context(a) <> "\n        generated: " <> context(b)
}

fn common_prefix(a: List(String), b: List(String), n: Int) -> Int {
  case a, b {
    [x, ..a], [y, ..b] if x == y -> common_prefix(a, b, n + 1)
    _, _ -> n
  }
}
