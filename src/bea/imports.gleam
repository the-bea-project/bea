//// Organising imports, `goimports` style. The language server does it when
//// a document is formatted, `bea format --imports` on the command line.
////
//// - Imports are grouped — the standard library and official packages
////   (`gleam/...`), other dependencies, then the project's own modules —
////   with a blank line between groups, and sorted within each group.
////   Unqualified names are sorted too, types first.
//// - Imports nothing refers to are removed, and so are unused unqualified
////   names. Usage is found on the syntax tree, scope aware: a variable
////   called `request` doesn't keep `import gleam/http/request`.
//// - A missing import is added when it is obvious: `request.new()` is used,
////   `request` isn't imported, and exactly one importable module is called
////   `request` and has a `new` (when two modules could be meant, nothing is
////   added). Standard library modules Bea imports by itself are left alone.
//// - Comments above an import move with it; a file that doesn't parse is
////   left untouched.

import bea/ast
import bea/codegen
import bea/lsp/index
import bea/parser
import bea/project.{type Project}
import bea/span.{Span}
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

/// What is known about the project the module belongs to.
pub type Known {
  Known(
    /// Modules of the project itself.
    internal: Set(String),
    /// Importable modules and the public names they export.
    exports: Dict(String, Set(String)),
    /// The module being organised.
    current: String,
  )
}

/// Nothing known: imports are still grouped, sorted and pruned, but none is
/// added and only `gleam/...` modules are told apart.
pub fn nothing_known() -> Known {
  Known(set.new(), dict.new(), "")
}

type Entry {
  Entry(
    module: String,
    alias: Option(String),
    unqualified: List(ast.Unqualified),
    /// Comment lines written above the import.
    comments: List(String),
    /// A comment at the end of the import's line.
    trailing: String,
  )
}

/// Organise the imports of `source`. Returns `source` unchanged when there
/// is nothing to do or the code doesn't parse.
pub fn organize(source: String, known: Known) -> String {
  let parsed = parser.parse_module(source)
  case parsed.errors {
    [_, ..] -> source
    [] -> organize_module(source, parsed.module, known)
  }
}

fn organize_module(source: String, module: ast.Module, known: Known) -> String {
  let refs = codegen.references(module)
  let imports =
    list.filter_map(module.items, fn(it) {
      case it {
        ast.Import(span:, module:, alias:, unqualified:, ..) ->
          Ok(#(span, module, option.map(alias, fn(a) { a.0 }), unqualified))
        _ -> Error(Nil)
      }
    })
  // The leading run of imports (only blank lines and comments between
  // them) is rewritten in place; imports further down join it.
  let #(run, stray) = split_run(source, imports)
  let entries =
    list.index_map(run, fn(i, n) {
      let #(s, m, alias, uq) = i
      let comments = case n {
        0 -> []
        _ -> {
          let assert Ok(#(prev, _, _, _)) = list.drop(run, n - 1) |> list.first
          comment_lines(slice(source, line_end(source, prev.end), s.start))
        }
      }
      Entry(m, alias, uq, comments, trailing_comment(source, s.end))
    })
    |> list.append(
      list.map(stray, fn(i) {
        let #(s, m, alias, uq) = i
        Entry(m, alias, uq, [], trailing_comment(source, s.end))
      }),
    )
  let kept = list.filter_map(entries, prune(_, refs))
  let kept = dedupe(kept)
  let added = additions(refs, kept, known)
  let all = list.append(kept, added)
  let block = render(all, known)
  case run, all {
    [], [] -> source
    [], _ -> insert_block(source, block)
    [first, ..], _ -> {
      let region_start = line_start(source, { first.0 }.start)
      let assert Ok(last) = list.last(run)
      let region_end = line_end(source, { last.0 }.end)
      let before = slice(source, 0, region_start)
      let after = slice(source, region_end, string.byte_size(source))
      let after = remove_stray(after, region_end, stray, source)
      case block {
        "" -> before <> string.trim_start(after)
        _ -> before <> block <> after
      }
    }
  }
}

/// What `bea/imports` needs to know about a project: its own modules and
/// the exports of every module (its own and its dependencies').
pub fn for_project(
  p: Project,
  deps: Option(index.Index),
  path: String,
  compiled_source: fn(String) -> Result(String, Nil),
) -> Known {
  let modules =
    project.source_files(p.src_dir)
    |> list.filter(fn(f) {
      string.ends_with(f, ".bea") || string.ends_with(f, ".gleam")
    })
  let bea_modules =
    list.filter_map(modules, fn(f) {
      case string.ends_with(f, ".bea") {
        False -> Error(Nil)
        True -> {
          let name = project.module_name(p, f)
          let source = case compiled_source(name) {
            Ok(s) -> Ok(s)
            Error(_) -> simplifile.read(f) |> result.replace_error(Nil)
          }
          result.map(source, fn(s) { #(name, parser.parse_module(s).module) })
        }
      }
    })
  let own = index.project_modules(p, bea_modules)
  let all = case deps {
    Some(d) -> dict.merge(d, own)
    None -> own
  }
  Known(
    internal: list.map(modules, fn(f) {
      project.module_name(p, f) |> string.replace(".gleam", "")
    })
      |> set.from_list,
    exports: dict.map_values(all, fn(_, entries) {
      list.map(entries, fn(e) { e.name }) |> set.from_list
    }),
    current: project.module_name(p, path),
  )
}

// --- Usage ------------------------------------------------------------------------

fn used_name(entry: Entry) -> String {
  case entry.alias {
    Some(a) -> a
    None -> last_segment(entry.module)
  }
}

pub fn last_segment(module: String) -> String {
  case string.split(module, "/") |> list.last {
    Ok(s) -> s
    Error(_) -> module
  }
}

/// The import without what isn't used, or nothing if none of it is.
fn prune(entry: Entry, refs: codegen.References) -> Result(Entry, Nil) {
  let unqualified =
    list.filter(entry.unqualified, fn(u) {
      let name = option.unwrap(u.alias, u.name)
      case u.is_type, is_upper(name) {
        True, _ -> set.contains(refs.unqualified, #(True, name))
        False, True -> set.contains(refs.unqualified, #(False, name))
        False, False -> set.contains(refs.values, name)
      }
    })
  let module_used = set.contains(refs.modules, used_name(entry))
  case module_used, unqualified {
    False, [] -> Error(Nil)
    _, _ -> Ok(Entry(..entry, unqualified:))
  }
}

fn dedupe(entries: List(Entry)) -> List(Entry) {
  list.fold(entries, [], fn(acc, e) {
    case
      list.any(acc, fn(x: Entry) { x.module == e.module && x.alias == e.alias })
    {
      True ->
        list.map(acc, fn(x) {
          case x.module == e.module && x.alias == e.alias {
            True ->
              Entry(
                ..x,
                unqualified: list.unique(list.append(
                  x.unqualified,
                  e.unqualified,
                )),
                comments: list.append(x.comments, e.comments),
              )
            False -> x
          }
        })
      False -> list.append(acc, [e])
    }
  })
}

/// Imports to add: modules used by qualifier that nothing imports, when
/// exactly one importable module fits.
fn additions(
  refs: codegen.References,
  kept: List(Entry),
  known: Known,
) -> List(Entry) {
  let imported = list.map(kept, used_name) |> set.from_list
  let std = list.map(codegen.std_modules, fn(m) { m.0 }) |> set.from_list
  refs.modules
  |> set.to_list
  |> list.sort(string.compare)
  |> list.filter(fn(q) { !set.contains(imported, q) && !set.contains(std, q) })
  |> list.filter_map(fn(q) {
    let members =
      set.to_list(refs.members)
      |> list.filter_map(fn(m) {
        case m.0 == q && !is_upper(m.1) {
          True -> Ok(m.1)
          False -> Error(Nil)
        }
      })
    let candidates =
      dict.to_list(known.exports)
      |> list.filter(fn(m) {
        let #(module, names) = m
        module != known.current
        && last_segment(module) == q
        && list.all(members, set.contains(names, _))
      })
    case candidates {
      [#(module, _)] -> Ok(Entry(module, None, [], [], ""))
      _ -> Error(Nil)
    }
  })
}

fn is_upper(name: String) -> Bool {
  case string.first(name) {
    Ok(c) -> string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", c)
    Error(_) -> False
  }
}

// --- Rendering ----------------------------------------------------------------------

/// 0: the standard library and official packages, 1: other dependencies,
/// 2: the project's own modules.
fn group(module: String, known: Known) -> Int {
  case
    set.contains(known.internal, module),
    module == "gleam" || string.starts_with(module, "gleam/")
  {
    True, _ -> 2
    False, True -> 0
    False, False -> 1
  }
}

fn render(entries: List(Entry), known: Known) -> String {
  entries
  |> list.sort(fn(a, b) {
    case int_compare(group(a.module, known), group(b.module, known)) {
      order.Eq -> string.compare(a.module, b.module)
      other -> other
    }
  })
  |> list.chunk(fn(e) { group(e.module, known) })
  |> list.map(fn(g) { list.map(g, render_entry) |> string.join("\n") })
  |> string.join("\n\n")
}

fn int_compare(a: Int, b: Int) -> order.Order {
  case a < b, a == b {
    True, _ -> order.Lt
    _, True -> order.Eq
    _, _ -> order.Gt
  }
}

fn render_entry(e: Entry) -> String {
  let unqualified =
    e.unqualified
    |> list.sort(fn(a, b) {
      case a.is_type, b.is_type {
        True, False -> order.Lt
        False, True -> order.Gt
        _, _ -> string.compare(a.name, b.name)
      }
    })
    |> list.map(fn(u) {
      case u.is_type {
        True -> "type "
        False -> ""
      }
      <> u.name
      <> case u.alias {
        Some(a) -> " as " <> a
        None -> ""
      }
    })
  let line =
    "import "
    <> e.module
    <> case unqualified {
      [] -> ""
      names -> ".{" <> string.join(names, ", ") <> "}"
    }
    <> case e.alias {
      Some(a) -> " as " <> a
      None -> ""
    }
    <> case e.trailing {
      "" -> ""
      c -> " " <> c
    }
  list.append(e.comments, [line]) |> string.join("\n")
}

// --- Text ----------------------------------------------------------------------------

type Import =
  #(span.Span, String, Option(String), List(ast.Unqualified))

fn split_run(
  source: String,
  imports: List(Import),
) -> #(List(Import), List(Import)) {
  case imports {
    [] -> #([], [])
    [first, ..rest] -> {
      let #(run, stray, _) =
        list.fold(rest, #([first], [], True), fn(acc, i) {
          let #(run, stray, open) = acc
          let assert [prev, ..] = run
          let between = slice(source, { prev.0 }.end, { i.0 }.start)
          case open && only_comments(between) {
            True -> #([i, ..run], stray, True)
            False -> #(run, [i, ..stray], False)
          }
        })
      #(list.reverse(run), list.reverse(stray))
    }
  }
}

fn only_comments(text: String) -> Bool {
  string.split(text, "\n")
  |> list.all(fn(l) {
    let t = string.trim(l)
    t == "" || string.starts_with(t, "//")
  })
}

fn comment_lines(text: String) -> List(String) {
  string.split(text, "\n")
  |> list.map(string.trim)
  |> list.filter(fn(l) { string.starts_with(l, "//") })
}

/// `// ...` after the import on its own line, if any.
fn trailing_comment(source: String, end: Int) -> String {
  let rest = string.trim(slice(source, end, line_end(source, end)))
  case string.starts_with(rest, "//") {
    True -> rest
    False -> ""
  }
}

/// Imports below the leading run are deleted (with their line).
fn remove_stray(
  after: String,
  after_start: Int,
  stray: List(Import),
  source: String,
) -> String {
  list.fold(list.reverse(stray), after, fn(text, i) {
    let start = line_start(source, { i.0 }.start) - after_start
    let end = line_end(source, { i.0 }.end) + 1 - after_start
    slice(text, 0, start) <> slice(text, end, string.byte_size(text))
  })
}

/// A module without imports gets the block after its module comment.
fn insert_block(source: String, block: String) -> String {
  let lines = string.split(source, "\n")
  let header =
    list.take_while(lines, fn(l) {
      let t = string.trim(l)
      t == "" || string.starts_with(t, "////")
    })
  let header = case list.any(header, fn(l) { string.trim(l) != "" }) {
    True -> header
    False -> []
  }
  let rest = list.drop(lines, list.length(header)) |> string.join("\n")
  let header = case header {
    [] -> ""
    _ -> string.trim_end(string.join(header, "\n")) <> "\n\n"
  }
  header <> block <> "\n\n" <> string.trim_start(rest)
}

fn line_start(source: String, offset: Int) -> Int {
  let before = slice(source, 0, offset)
  case string.split(before, "\n") |> list.last {
    Ok(last) -> offset - string.byte_size(last)
    Error(_) -> 0
  }
}

fn line_end(source: String, offset: Int) -> Int {
  let after = slice(source, offset, string.byte_size(source))
  case string.split_once(after, "\n") {
    Ok(#(rest_of_line, _)) -> offset + string.byte_size(rest_of_line)
    Error(_) -> string.byte_size(source)
  }
}

fn slice(text: String, from: Int, to: Int) -> String {
  span.text(text, Span(from, to))
}
