//// An index of the public functions, constants and constructors of every
//// module the project can import: its Bea modules, hand written Gleam
//// modules, and the Gleam sources of its dependencies.
////
//// `gleam lsp` knows the types; this index adds what Gleam's answers leave
//// out: parameter names and labels (for signature help and hovers), and
//// the values of modules that aren't imported yet (for completions that add
//// the import). Gleam sources are read with a small, forgiving scanner
//// rather than a full parser: only declaration headers matter.
////
//// It also finds the Erlang / JavaScript functions behind `@external`s.

import bea/ast
import bea/formatter
import bea/lsp/text
import bea/project.{type Project}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

pub type Kind {
  Function
  Constant
  Constructor
}

pub type Param {
  Param(label: Option(String), name: String, type_: String)
}

pub type Entry {
  Entry(
    /// Gleam module path, e.g. `gleam/time/timestamp`.
    module: String,
    name: String,
    kind: Kind,
    params: List(Param),
    /// As written in the source; "" when not annotated.
    return_type: String,
    /// Markdown, from the doc comment.
    doc: String,
  )
}

/// Modules and their public values.
pub type Index =
  Dict(String, List(Entry))

// --- Bea modules -------------------------------------------------------------------

pub fn from_bea(module: String, parsed: ast.Module) -> List(Entry) {
  list.flat_map(parsed.items, fn(item) {
    case item {
      ast.Function(name:, clauses:, ..) ->
        case list.any(clauses, fn(c) { c.publicity == ast.Public }) {
          False -> []
          True -> [bea_function(module, name, clauses)]
        }
      ast.Const(publicity: ast.Public, name:, annotation:, doc:, ..) -> [
        Entry(
          module,
          name,
          Constant,
          [],
          option.map(annotation, formatter.type_to_string)
            |> option.unwrap(""),
          doc_text(doc),
        ),
      ]
      ast.CustomType(
        publicity: ast.Public,
        opaque_: False,
        name:,
        variants:,
        ..,
      ) ->
        list.map(variants, fn(v) {
          Entry(
            module,
            v.name,
            Constructor,
            list.index_map(v.fields, fn(f, i) {
              Param(
                None,
                option.unwrap(f.label, "arg" <> int_suffix(i)),
                formatter.type_to_string(f.type_),
              )
            }),
            name,
            doc_text(v.doc),
          )
        })
      _ -> []
    }
  })
}

fn int_suffix(i: Int) -> String {
  case i {
    0 -> ""
    _ -> "_" <> string.inspect(i + 1)
  }
}

fn bea_function(
  module: String,
  name: String,
  clauses: List(ast.Clause),
) -> Entry {
  let assert [first, ..] = clauses
  // Parameter names: the first clause that binds a plain name at a position
  // wins (multi-clause functions often match on constructors).
  let params =
    list.index_map(first.params, fn(p, i) {
      let name =
        clauses
        |> list.find_map(fn(c) {
          case list.drop(c.params, i) {
            [cp, ..] -> pattern_name(cp.pattern)
            [] -> Error(Nil)
          }
        })
        |> result.unwrap("arg" <> int_suffix(i))
      let type_ =
        clauses
        |> list.find_map(fn(c) {
          case list.drop(c.params, i) {
            [ast.Param(annotation: Some(t), ..), ..] ->
              Ok(formatter.type_to_string(t))
            _ -> Error(Nil)
          }
        })
        |> result.unwrap("")
      Param(p.label, name, type_)
    })
  let return_type =
    list.find_map(clauses, fn(c) {
      option.to_result(c.return_type, Nil)
      |> result.map(formatter.type_to_string)
    })
    |> result.unwrap("")
  let doc =
    list.find_map(clauses, fn(c) {
      case c.doc {
        [] -> Error(Nil)
        d -> Ok(doc_text(d))
      }
    })
    |> result.unwrap("")
  Entry(module, name, Function, params, return_type, doc)
}

fn pattern_name(p: ast.Pattern) -> Result(String, Nil) {
  case p {
    ast.PVar(name:, ..) -> Ok(name)
    ast.PAssign(name:, ..) -> Ok(name)
    _ -> Error(Nil)
  }
}

fn doc_text(lines: List(String)) -> String {
  lines
  |> list.map(fn(l) {
    case l {
      "///" <> rest -> rest
      _ -> l
    }
  })
  |> list.map(fn(l) {
    case l {
      " " <> rest -> rest
      _ -> l
    }
  })
  |> string.join("\n")
}

// --- Gleam sources -----------------------------------------------------------------

/// Public declarations of a Gleam module, read from its source.
pub fn from_gleam(module: String, source: String) -> List(Entry) {
  scan_gleam(module, string.split(source, "\n"), [], [])
}

fn scan_gleam(
  module: String,
  lines: List(String),
  doc: List(String),
  acc: List(Entry),
) -> List(Entry) {
  case lines {
    [] -> list.reverse(acc)
    [line, ..rest] -> {
      let trimmed = string.trim_start(line)
      case line {
        "///" <> d -> scan_gleam(module, rest, [strip_space(d), ..doc], acc)
        "@" <> _ -> scan_gleam(module, rest, doc, acc)
        "pub fn " <> after -> {
          let header = gather_header(after, rest)
          let entry = function_header(module, header, doc_join(doc))
          scan_gleam(module, rest, [], prepend(entry, acc))
        }
        "pub const " <> after -> {
          let name = take_name(after)
          let type_ = case string.split_once(after, ":") {
            Ok(#(_, t)) ->
              case string.split_once(t, "=") {
                Ok(#(t, _)) -> string.trim(t)
                Error(_) -> ""
              }
            Error(_) -> ""
          }
          let acc = case name {
            "" -> acc
            _ -> [
              Entry(module, name, Constant, [], type_, doc_join(doc)),
              ..acc
            ]
          }
          scan_gleam(module, rest, [], acc)
        }
        "pub type " <> after -> {
          let type_name = take_upper_name(after)
          case string.contains(line, "{") {
            True -> {
              let #(constructors, rest) =
                constructors(module, type_name, rest, [], [])
              scan_gleam(module, rest, [], list.append(constructors, acc))
            }
            False -> scan_gleam(module, rest, [], acc)
          }
        }
        _ ->
          case trimmed {
            "" -> scan_gleam(module, rest, [], acc)
            _ -> scan_gleam(module, rest, [], acc)
          }
      }
    }
  }
}

fn prepend(entry: Result(Entry, Nil), acc: List(Entry)) -> List(Entry) {
  case entry {
    Ok(e) -> [e, ..acc]
    Error(_) -> acc
  }
}

fn strip_space(s: String) -> String {
  case s {
    " " <> rest -> rest
    _ -> s
  }
}

fn doc_join(doc: List(String)) -> String {
  doc |> list.reverse |> string.join("\n")
}

/// The text of a declaration header, which may span several lines: up to
/// the body's `{`, or the end of the parameter list's line for externals.
fn gather_header(first: String, rest: List(String)) -> String {
  gather(first, rest, 0)
}

fn gather(acc: String, rest: List(String), n: Int) -> String {
  case balanced_params(acc), rest {
    True, _ -> acc
    False, [next, ..more] if n < 40 -> gather(acc <> "\n" <> next, more, n + 1)
    False, _ -> acc
  }
}

fn balanced_params(s: String) -> Bool {
  case string.split_once(s, "(") {
    Error(_) -> True
    Ok(#(_, after)) -> text.depth_after(after) < 0
  }
}

fn function_header(
  module: String,
  header: String,
  doc: String,
) -> Result(Entry, Nil) {
  let name = take_name(header)
  case name, string.split_once(header, "(") {
    "", _ -> Error(Nil)
    _, Error(_) -> Error(Nil)
    _, Ok(#(_, after)) -> {
      let #(inside, tail) = text.split_at_close(after)
      let params =
        text.split_top_level(inside, ",")
        |> list.map(string.trim)
        |> list.filter(fn(p) { p != "" })
        |> list.index_map(parse_param)
      let return_type = case string.trim_start(tail) {
        "->" <> r ->
          r
          |> text.until_top_level("{")
          |> string.split("\n")
          |> list.first
          |> result.unwrap("")
          |> string.trim
        _ -> ""
      }
      Ok(Entry(module, name, Function, params, return_type, doc))
    }
  }
}

fn parse_param(p: String, i: Int) -> Param {
  let p = strip_comments(p)
  let #(left, type_) = case text.split_top_level(p, ":") {
    [left, ..types] -> #(left, string.join(types, ":") |> string.trim)
    [] -> #(p, "")
  }
  case string.split(string.trim(left), " ") |> list.filter(fn(w) { w != "" }) {
    [label, name] -> Param(Some(label), name, type_)
    [name] -> Param(None, name, type_)
    _ -> Param(None, "arg" <> int_suffix(i), type_)
  }
}

fn strip_comments(p: String) -> String {
  string.split(p, "\n")
  |> list.map(fn(line) {
    case string.split_once(line, "//") {
      Ok(#(code, _)) -> code
      Error(_) -> line
    }
  })
  |> string.join(" ")
  |> string.trim
}

/// Constructors of `pub type Name {` until the closing `}` in column 0.
fn constructors(
  module: String,
  type_name: String,
  lines: List(String),
  doc: List(String),
  acc: List(Entry),
) -> #(List(Entry), List(String)) {
  case lines {
    [] -> #(acc, [])
    ["}" <> _, ..rest] -> #(acc, rest)
    [line, ..rest] -> {
      let trimmed = string.trim(line)
      case trimmed {
        "///" <> d ->
          constructors(module, type_name, rest, [strip_space(d), ..doc], acc)
        "" -> constructors(module, type_name, rest, [], acc)
        _ -> {
          let name = take_upper_name(trimmed)
          case name {
            "" -> constructors(module, type_name, rest, [], acc)
            _ -> {
              let header = gather(trimmed, rest, 0)
              let skip = list.length(string.split(header, "\n")) - 1
              let params = case string.split_once(header, "(") {
                Ok(#(_, after)) ->
                  text.split_at_close(after).0
                  |> text.split_top_level(",")
                  |> list.map(string.trim)
                  |> list.filter(fn(p) { p != "" })
                  |> list.index_map(fn(p, i) {
                    // Constructor fields are `label: Type` or just `Type`.
                    case text.split_top_level(p, ":") {
                      [label, type_, ..] ->
                        Param(None, string.trim(label), string.trim(type_))
                      _ -> Param(None, "arg" <> int_suffix(i), string.trim(p))
                    }
                  })
                Error(_) -> []
              }
              let entry =
                Entry(
                  module,
                  name,
                  Constructor,
                  params,
                  type_name,
                  doc_join(doc),
                )
              constructors(module, type_name, list.drop(rest, skip), [], [
                entry,
                ..acc
              ])
            }
          }
        }
      }
    }
  }
}

fn take_name(s: String) -> String {
  take_while(s, "abcdefghijklmnopqrstuvwxyz0123456789_")
}

fn take_upper_name(s: String) -> String {
  case
    take_while(
      s,
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_",
    )
  {
    "" -> ""
    name ->
      case string.first(name) {
        Ok(c) ->
          case string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c) {
            True -> name
            False -> ""
          }
        Error(_) -> ""
      }
  }
}

fn take_while(s: String, allowed: String) -> String {
  s
  |> string.to_graphemes
  |> list.take_while(fn(c) { string.contains(allowed, c) })
  |> string.concat
}

// --- Whole projects ----------------------------------------------------------------

/// The project's own modules: Bea modules (from their syntax trees) and
/// hand written Gleam modules in `src/`.
pub fn project_modules(
  p: Project,
  bea_modules: List(#(String, ast.Module)),
) -> Index {
  let bea =
    list.map(bea_modules, fn(m) { #(m.0, from_bea(m.0, m.1)) })
    |> dict.from_list
  project.source_files(p.src_dir)
  |> list.filter(fn(f) { string.ends_with(f, ".gleam") })
  |> list.fold(bea, fn(acc, path) {
    let module =
      string.drop_start(path, string.length(p.src_dir) + 1)
      |> string.drop_end(6)
    case simplifile.read(path) {
      Ok(source) -> dict.insert(acc, module, from_gleam(module, source))
      Error(_) -> acc
    }
  })
}

/// Public modules of the downloaded dependencies (`internal` modules are
/// left out, as Gleam does).
pub fn dependencies(p: Project) -> Index {
  let packages = p.build_dir <> "/build/packages"
  simplifile.read_directory(packages)
  |> result.unwrap([])
  |> list.flat_map(fn(package) {
    let src = packages <> "/" <> package <> "/src"
    project.source_files(src)
    |> list.filter(fn(f) { string.ends_with(f, ".gleam") })
    |> list.filter_map(fn(path) {
      let module =
        string.drop_start(path, string.length(src) + 1) |> string.drop_end(6)
      case list.contains(string.split(module, "/"), "internal") {
        True -> Error(Nil)
        False ->
          simplifile.read(path)
          |> result.map(fn(source) { #(module, from_gleam(module, source)) })
          |> result.replace_error(Nil)
      }
    })
  })
  |> dict.from_list
}

pub fn lookup(index: Index, module: String, name: String) -> Option(Entry) {
  dict.get(index, module)
  |> result.try(list.find(_, fn(e) { e.name == name }))
  |> option.from_result
}

// --- Rendering ----------------------------------------------------------------------

/// `name(label name: Type, ...) -> Return`
pub fn signature(entry: Entry, qualifier: Option(String)) -> String {
  let name = case qualifier {
    Some(q) -> q <> "." <> entry.name
    None -> entry.name
  }
  case entry.kind {
    Constant ->
      name
      <> case entry.return_type {
        "" -> ""
        t -> ": " <> t
      }
    Function | Constructor -> {
      let params =
        list.map(entry.params, param_string)
        |> string.join(", ")
      let return = case entry.kind, entry.return_type {
        Constructor, _ | _, "" -> ""
        _, t -> " -> " <> t
      }
      case entry.kind, entry.params {
        Constructor, [] -> name
        _, _ -> name <> "(" <> params <> ")" <> return
      }
    }
  }
}

pub fn param_string(p: Param) -> String {
  let label = case p.label {
    // `date date: Date` reads better as `date: Date`.
    Some(l) if l == p.name -> ""
    Some(l) -> l <> " "
    None -> ""
  }
  label
  <> p.name
  <> case p.type_ {
    "" -> ""
    t -> ": " <> t
  }
}

// --- FFI ------------------------------------------------------------------------------

pub type Foreign {
  Foreign(path: String, line: Int, snippet: String, language: String)
}

/// The Erlang function `module:function` among the project's and its
/// dependencies' `.erl` files.
pub fn find_erlang(
  p: Project,
  module: String,
  function: String,
) -> Option(Foreign) {
  let file = module <> ".erl"
  let packages = p.build_dir <> "/build/packages"
  let dirs = [
    p.src_dir,
    ..{
      simplifile.read_directory(packages)
      |> result.unwrap([])
      |> list.map(fn(d) { packages <> "/" <> d <> "/src" })
    }
  ]
  dirs
  |> list.flat_map(project.source_files)
  |> list.filter(fn(f) { f == file || string.ends_with(f, "/" <> file) })
  |> list.find_map(fn(path) {
    simplifile.read(path)
    |> result.replace_error(Nil)
    |> result.try(fn(source) {
      find_definition(source, fn(line) {
        string.starts_with(line, function <> "(")
      })
      |> result.map(fn(found) {
        Foreign(path, found.0, snippet(source, found.0, "%", "-spec"), "erlang")
      })
    })
  })
  |> option.from_result
}

/// The JavaScript function exported as `function` from `path` (relative to
/// the module doing the import).
pub fn find_javascript(
  importer_dir: String,
  path: String,
  function: String,
) -> Option(Foreign) {
  let full = case path {
    "./" <> rest -> importer_dir <> "/" <> rest
    "/" <> _ -> path
    _ -> importer_dir <> "/" <> path
  }
  let full = normalise(full)
  simplifile.read(full)
  |> result.replace_error(Nil)
  |> result.try(fn(source) {
    find_definition(source, fn(line) {
      list.any(
        [
          "export function " <> function <> "(",
          "export async function " <> function <> "(",
          "export function* " <> function <> "(",
          "export const " <> function <> " ",
          "export const " <> function <> "=",
          "export let " <> function <> " ",
        ],
        string.starts_with(line, _),
      )
    })
    |> result.map(fn(found) {
      Foreign(full, found.0, snippet(source, found.0, "//", "@"), "javascript")
    })
  })
  |> option.from_result
}

fn normalise(path: String) -> String {
  string.split(path, "/")
  |> list.fold([], fn(acc, part) {
    case part, acc {
      "..", [_, ..rest] -> rest
      ".", _ -> acc
      _, _ -> [part, ..acc]
    }
  })
  |> list.reverse
  |> string.join("/")
}

fn find_definition(
  source: String,
  matches: fn(String) -> Bool,
) -> Result(#(Int, String), Nil) {
  string.split(source, "\n")
  |> list.index_map(fn(line, i) { #(i, line) })
  |> list.find(fn(l) { matches(l.1) })
}

/// The comment / spec lines right above a definition, and its first lines.
fn snippet(
  source: String,
  line: Int,
  comment: String,
  annotation: String,
) -> String {
  let lines = string.split(source, "\n")
  let above =
    list.take(lines, line)
    |> list.reverse
    |> list.take_while(fn(l) {
      let t = string.trim_start(l)
      string.starts_with(t, comment)
      || string.starts_with(t, annotation)
      || string.starts_with(t, "*")
      || string.starts_with(t, "/*")
    })
    |> list.reverse
  let body =
    list.drop(lines, line)
    |> take_until_end(0, [])
  list.append(above, body) |> string.join("\n")
}

/// Lines of a definition, up to its end or 12 lines.
fn take_until_end(
  lines: List(String),
  n: Int,
  acc: List(String),
) -> List(String) {
  case lines {
    [] -> list.reverse(acc)
    _ if n >= 12 -> list.reverse(["...", ..acc])
    [l, ..rest] -> {
      let acc = [l, ..acc]
      let t = string.trim_end(l)
      case
        n > 0
        && { t == "}" || t == "};" }
        || string.ends_with(t, ".")
        && !string.ends_with(t, "..")
      {
        True -> list.reverse(acc)
        False -> take_until_end(rest, n + 1, acc)
      }
    }
  }
}
