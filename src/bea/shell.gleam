//// `bea shell`: an interactive Bea shell, built on GSH (the Gleam shell,
//// https://gsh.hexdocs.pm), which is a dependency of Bea.
////
//// Every input is Bea. It is compiled to Gleam by Bea's own pipeline and
//// handed to GSH's evaluator, which compiles it against the project
//// (`.beabuild/`), hot loads it into this VM and keeps the session's
//// bindings, imports, types and functions — side effects of earlier inputs
//// run only once. Results come back in Bea syntax and Bea's colours.
////
//// - Statements and expressions are evaluated one statement at a time.
//// - `def`, `type`, `const` and `import` define things for later inputs
////   (redefining replaces). Standard library modules are imported by
////   themselves, as in Bea files.
//// - Inputs continue on the next line while brackets or a string are open.
////
//// GSH's evaluator is internal API, which is why the dependency is pinned
//// to one minor version in `gleam.toml`.

import bea/ast
import bea/codegen
import bea/compiler
import bea/diagnostic
import bea/highlight
import bea/line_editor
import bea/lsp/repair
import bea/parser
import bea/project.{type Project}
import bea/span.{Span}
import bea/style
import bea/system
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/regexp
import gleam/result
import gleam/string
import gsh/internal/evaluator/binding.{type Binding}
import gsh/internal/evaluator/evaluator
import gsh/internal/evaluator/result as gsh_result
import gsh/internal/evaluator/target
import gsh/internal/runtime/runtime
import simplifile

type Session {
  Session(
    count: Int,
    bindings: List(Binding),
    /// Gleam `import` lines, one per module.
    imports: List(String),
    types: List(#(String, String)),
    functions: List(#(String, String)),
    /// Print the Gleam each input compiles to.
    show_gleam: Bool,
    colour: Bool,
    /// Inputs, most recent first (kept in the cache directory).
    history: List(String),
  )
}

@external(erlang, "bea_ffi", "set_cwd")
fn set_cwd(path: String) -> Nil

@external(erlang, "bea_ffi", "prepend_to_path")
fn prepend_to_path(dir: String) -> Nil

@external(erlang, "bea_ffi", "shell_code_paths")
fn code_paths(build_dir: String, package: String) -> List(String)

@external(erlang, "bea_ffi", "package_dir")
fn package_dir(name: String) -> Result(String, Nil)

/// Packages the modules GSH generates import (`simplifile`, and what it
/// depends on). GSH is normally a dependency of the project itself; here it
/// is Bea's, so they may be missing from the project's build.
const support_packages = ["simplifile", "filepath"]

/// Make the support packages Bea was built with available to the project's
/// build, when it doesn't have them. Returns the ones that couldn't be.
fn provide_support_packages(p: Project) -> List(String) {
  let lib = p.build_dir <> "/build/dev/erlang/"
  list.filter(support_packages, fn(name) {
    case simplifile.is_directory(lib <> name <> "/_gleam_artefacts") {
      Ok(True) -> False
      _ ->
        case package_dir(name) {
          Error(_) -> True
          Ok(dir) ->
            case simplifile.is_directory(dir <> "/_gleam_artefacts") {
              Ok(True) ->
                simplifile.copy_directory(dir, lib <> name) |> result.is_error
              _ -> True
            }
        }
    }
  })
}

/// Start the shell for a project that has just been built. `rebuild`
/// syncs and builds it again (`:cc`), returning whether that worked.
pub fn start(p: Project, gleam: String, rebuild: fn() -> Bool) -> Int {
  let colour = system.colour()
  // GSH runs `gleam` from the generated project.
  prepend_to_path(project.dirname(gleam))
  set_cwd(p.build_dir)
  let missing = provide_support_packages(p)
  let clashes = code_paths(p.build_dir, p.name)
  runtime.trap_exits()
  let session = Session(1, [], [], [], [], False, colour, load_history())
  banner(session, p, clashes)
  case missing {
    [] -> loop(session, rebuild)
    _ -> {
      error(
        session,
        "the shell needs "
          <> string.join(missing, " and ")
          <> " in the project: run `bea add "
          <> string.join(missing, " ")
          <> " --dev` first.",
      )
      1
    }
  }
}

fn banner(s: Session, p: Project, clashes: List(String)) -> Nil {
  let paint = painter(s)
  io.println(
    paint(style.accent, "Bea shell")
    <> paint(style.dim, " · " <> p.name <> " · powered by GSH"),
  )
  io.println(paint(style.dim, "Type Bea code, :help for commands, :q to quit."))
  case clashes {
    [] -> Nil
    _ ->
      io.println(
        paint(style.warning, "warning")
        <> ": these project modules share a name with modules the shell"
        <> " itself uses, and can't be loaded: "
        <> string.join(clashes, ", ")
        <> paint(
          style.dim,
          "\nRename them (e.g. `" <> p.name <> "_ffi.erl`) to use them here.",
        ),
      )
  }
}

fn painter(s: Session) -> fn(fn(String) -> String, String) -> String {
  fn(f, text) {
    case s.colour {
      True -> f(text)
      False -> text
    }
  }
}

fn loop(s: Session, rebuild: fn() -> Bool) -> Int {
  case read_input(s, "", "bea> ") {
    Error(_) -> {
      save_history(s.history)
      0
    }
    Ok(input) -> {
      let s = case string.trim(input) {
        "" -> s
        trimmed -> Session(..s, history: [trimmed, ..s.history])
      }
      case string.trim(input) {
        "" -> loop(s, rebuild)
        ":q" | ":quit" | ":exit" -> {
          save_history(s.history)
          0
        }
        ":" <> command -> loop(command_(s, command, rebuild), rebuild)
        _ -> loop(evaluate(s, input), rebuild)
      }
    }
  }
}

/// Read lines until brackets and strings are closed. Ctrl+C drops what was
/// typed; Ctrl+D (or the end of the input) leaves the shell.
fn read_input(s: Session, sofar: String, p: String) -> Result(String, Nil) {
  let painted = case s.colour {
    True -> style.prompt(p)
    False -> p
  }
  let paint = case s.colour {
    True -> highlight.bea
    False -> fn(x) { x }
  }
  case line_editor.read(painted, string.length(p), s.history, paint) {
    line_editor.Eof -> Error(Nil)
    line_editor.Cancelled -> Ok("")
    line_editor.Line(line) -> {
      let text = case sofar {
        "" -> line
        _ -> sofar <> "\n" <> line
      }
      let scan = repair.scan(text)
      case scan.open != [] || scan.in_string {
        True -> read_input(s, text, "...> ")
        False -> Ok(string.trim_end(text))
      }
    }
  }
}

fn history_file() -> String {
  let cache = case system.get_env("XDG_CACHE_HOME"), system.get_env("HOME") {
    Ok(dir), _ -> dir
    _, Ok(home) -> home <> "/.cache"
    _, _ -> "/tmp"
  }
  cache <> "/bea/shell_history"
}

/// Entries are separated by NUL bytes (they can span several lines).
fn load_history() -> List(String) {
  case simplifile.read(history_file()) {
    Ok(text) ->
      string.split(text, "\u{0}")
      |> list.filter(fn(e) { e != "" })
      |> list.reverse
    Error(_) -> []
  }
}

fn save_history(history: List(String)) -> Nil {
  let _ = simplifile.create_directory_all(project.dirname(history_file()))
  let _ =
    history
    |> list.take(500)
    |> list.reverse
    |> string.join("\u{0}")
    |> simplifile.write(history_file(), _)
  Nil
}

// --- Commands ------------------------------------------------------------------------

fn command_(s: Session, command: String, rebuild: fn() -> Bool) -> Session {
  let paint = painter(s)
  case string.trim(command) {
    "h" | "help" -> {
      [
        #(":help", "this help"),
        #(":q", "quit (or Ctrl+D)"),
        #(":b", "the bindings of this session"),
        #(":i", "the imports of this session"),
        #(":gleam", "show the Gleam each input compiles to (toggle)"),
        #(":cc", "rebuild the project and reload what changed"),
        #(":reset", "forget all bindings, imports and definitions"),
      ]
      |> list.each(fn(c) {
        io.println(
          "  " <> paint(style.highlight, string.pad_end(c.0, 8, " ")) <> c.1,
        )
      })
      s
    }
    "b" | "bindings" -> {
      case s.bindings {
        [] -> io.println(paint(style.dim, "no bindings yet"))
        _ ->
          list.each(s.bindings, fn(b) {
            io.println(show_code(s, binding_to_bea(b.source)))
          })
      }
      s
    }
    "i" | "imports" -> {
      case s.imports {
        [] -> io.println(paint(style.dim, "no imports yet"))
        _ -> list.each(s.imports, fn(i) { io.println(show_code(s, i)) })
      }
      s
    }
    "gleam" -> {
      let show_gleam = !s.show_gleam
      io.println(
        paint(style.dim, case show_gleam {
          True -> "showing the generated Gleam"
          False -> "hiding the generated Gleam"
        }),
      )
      Session(..s, show_gleam:)
    }
    "cc" -> {
      case rebuild() {
        True ->
          case runtime.reload_modified() {
            [] -> io.println(paint(style.dim, "Ok"))
            modules ->
              io.println(
                paint(style.dim, "Ok, reloaded: ")
                <> string.join(
                  list.map(modules, string.replace(_, "@", "/")),
                  ", ",
                ),
              )
          }
        False -> Nil
      }
      s
    }
    "reset" -> Session(..s, bindings: [], imports: [], types: [], functions: [])
    other -> {
      error(s, "Unknown command `:" <> other <> "`, try :help")
      s
    }
  }
}

fn error(s: Session, message: String) -> Nil {
  io.println(painter(s)(style.error, "error") <> ": " <> message)
}

fn show_code(s: Session, code: String) -> String {
  case s.colour {
    True -> highlight.bea(code)
    False -> code
  }
}

// --- Evaluation ------------------------------------------------------------------------

/// An input is either definitions (`def`, `type`, `const`, `import`) or
/// statements.
fn evaluate(s: Session, input: String) -> Session {
  let as_module = parser.parse_module(input)
  case as_module.errors, as_module.module.items {
    [], [_, ..] -> definitions(s, input, as_module.module)
    _, _ -> statements(s, input)
  }
}

fn definitions(s: Session, input: String, module: ast.Module) -> Session {
  case compiler.compile_module(module, codegen.empty_context()) {
    Error(diagnostics) -> {
      report(s, diagnostics, input, 0)
      s
    }
    Ok(compiled) -> {
      let #(imports, items) = split_gleam(compiled.gleam)
      use s <- try_imports(s, imports)
      list.fold(items, s, fn(s, item) { run(s, item, "") })
    }
  }
}

const wrapper = "pub def bea_shell_input() {\n"

fn statements(s: Session, input: String) -> Session {
  let wrapped = wrapper <> input <> "\n}\n"
  let parsed = parser.parse_module(wrapped)
  case parsed.errors, parsed.module.items {
    [], [ast.Function(clauses: [ast.Clause(body: Some(body), ..)], ..)] ->
      list.fold_until(body, s, fn(s, stmt) {
        case one_statement(s, input, stmt) {
          Ok(s) -> list.Continue(s)
          Error(s) -> list.Stop(s)
        }
      })
    errors, _ -> {
      report(s, errors, input, string.byte_size(wrapper))
      s
    }
  }
}

fn one_statement(
  s: Session,
  input: String,
  stmt: ast.Statement,
) -> Result(Session, Session) {
  let offset = string.byte_size(wrapper)
  let source =
    span.text(
      wrapper <> input,
      Span(ast.statement_span(stmt).start, ast.statement_span(stmt).end),
    )
  case early_exit(stmt) {
    True -> {
      error(
        s,
        "`?`, `return` and `else` guards leave a function, so they need one: "
          <> "wrap this in a `def`.",
      )
      Error(s)
    }
    False -> {
      let module =
        ast.Module(
          [
            ast.Function(span.empty, "bea_shell_input", span.empty, [
              ast.Clause(
                span.empty,
                [],
                [],
                ast.Public,
                span.empty,
                [],
                None,
                None,
                Some([stmt]),
              ),
            ]),
          ],
          [],
        )
      case compiler.compile_module(module, codegen.empty_context()) {
        Error(diagnostics) -> {
          report(s, diagnostics, input, offset)
          Error(s)
        }
        Ok(compiled) -> {
          let #(imports, items) = split_gleam(compiled.gleam)
          let body = case items {
            [function, ..] -> function_body(function)
            [] -> source
          }
          let before = s.count
          let s = try_imports(s, imports, fn(s) { run(s, body, source) })
          case s.count > before {
            True -> Ok(s)
            False -> Error(s)
          }
        }
      }
    }
  }
}

/// `?`, `return` and guards make no sense outside a function.
fn early_exit(stmt: ast.Statement) -> Bool {
  case stmt {
    ast.Return(..) | ast.Guard(..) -> True
    _ -> string.contains(string.inspect(stmt), "Try(")
  }
}

/// Generated Gleam: its import lines and its other items.
fn split_gleam(gleam: String) -> #(List(String), List(String)) {
  let chunks =
    gleam
    |> string.trim
    |> string.split("\n\n")
    |> list.fold([], fn(acc, chunk) {
      // A blank line inside an item doesn't start a new one.
      case
        acc,
        string.starts_with(chunk, " ") || string.starts_with(chunk, "}")
      {
        [last, ..rest], True -> [last <> "\n\n" <> chunk, ..rest]
        _, _ -> [chunk, ..acc]
      }
    })
    |> list.reverse
  let #(imports, items) =
    list.partition(chunks, fn(c) { string.starts_with(c, "import ") })
  #(list.flat_map(imports, string.split(_, "\n")), items)
}

/// The statements of `pub fn bea_shell_input() { ... }`.
fn function_body(function: String) -> String {
  function
  |> string.split("\n")
  |> list.drop(1)
  |> list.reverse
  |> list.drop(1)
  |> list.reverse
  |> list.map(fn(line) {
    case line {
      "  " <> rest -> rest
      _ -> line
    }
  })
  |> string.join("\n")
}

/// Imports the input needs that the session doesn't have yet: new modules
/// are checked by GSH, imports of a module already imported are merged.
fn try_imports(
  s: Session,
  imports: List(String),
  next: fn(Session) -> Session,
) -> Session {
  let result =
    list.try_fold(imports, s, fn(s, line) {
      let merged = merge_import(s.imports, line)
      case merged == s.imports {
        True -> Ok(s)
        False -> {
          let outcome =
            evaluator.evaluate(
              import_line(merged, line),
              s.bindings,
              list.filter(s.imports, fn(i) {
                import_module(i) != import_module(line)
              }),
              s.types,
              s.functions,
              False,
              s.count,
              target.Local,
            )
          case outcome.success {
            True -> Ok(Session(..s, imports: merged, count: s.count + 1))
            False -> {
              print_failure(s, outcome)
              Error(Session(..s, count: s.count + 1))
            }
          }
        }
      }
    })
  case result {
    Ok(s) -> next(s)
    Error(s) -> s
  }
}

fn import_module(line: String) -> String {
  line
  |> string.drop_start(7)
  |> string.split(".{")
  |> list.first
  |> result.unwrap("")
  |> string.split(" as ")
  |> list.first
  |> result.unwrap("")
  |> string.trim
}

fn import_line(imports: List(String), line: String) -> String {
  list.find(imports, fn(i) { import_module(i) == import_module(line) })
  |> result.unwrap(line)
}

/// Add an import line, merging the unqualified names of a module that is
/// imported already.
fn merge_import(imports: List(String), line: String) -> List(String) {
  let module = import_module(line)
  case list.find(imports, fn(i) { import_module(i) == module }) {
    Error(_) -> list.append(imports, [line])
    Ok(existing) -> {
      let names = fn(l: String) {
        case string.split_once(l, ".{") {
          Ok(#(_, rest)) ->
            rest
            |> string.split("}")
            |> list.first
            |> result.unwrap("")
            |> string.split(",")
            |> list.map(string.trim)
            |> list.filter(fn(n) { n != "" })
          Error(_) -> []
        }
      }
      let all = list.unique(list.append(names(existing), names(line)))
      let alias = case string.split_once(existing, "} as ") {
        Ok(#(_, a)) -> " as " <> a
        Error(_) ->
          case string.contains(existing, ".{") {
            True -> ""
            False ->
              case string.split_once(existing, " as ") {
                Ok(#(_, a)) -> " as " <> a
                Error(_) -> ""
              }
          }
      }
      let merged = case all {
        [] -> "import " <> module <> alias
        _ ->
          "import " <> module <> ".{" <> string.join(all, ", ") <> "}" <> alias
      }
      list.map(imports, fn(i) {
        case i == existing {
          True -> merged
          False -> i
        }
      })
    }
  }
}

/// Evaluate one piece of Gleam with GSH, updating the session the way GSH's
/// own shell does.
fn run(s: Session, gleam: String, bea_source: String) -> Session {
  case s.show_gleam {
    True ->
      io.println(
        painter(s)(style.faint, "gleam› ") <> show_gleam_code(s, gleam),
      )
    False -> Nil
  }
  let outcome =
    evaluator.evaluate(
      gleam,
      s.bindings,
      s.imports,
      s.types,
      s.functions,
      False,
      s.count,
      target.Local,
    )
  let s = Session(..s, count: s.count + 1)
  case outcome.success {
    False -> {
      print_failure(s, outcome)
      // The count says whether evaluation went on; keep it unchanged.
      Session(..s, count: s.count - 1)
    }
    True -> {
      print_value(s, outcome.output)
      let defined = case outcome.new_binding, outcome.new_function {
        Some(b), _ -> b.names
        _, Some(f) -> [f.0]
        _, _ -> []
      }
      let current = option.unwrap(outcome.active_bindings, s.bindings)
      let kept =
        list.filter(current, fn(b) {
          list.any(b.names, fn(n) {
            !list.contains(defined, n) || string.contains(bea_source, n)
          })
        })
      let bindings = case outcome.new_binding {
        Some(b) -> list.append(kept, [b])
        None -> kept
      }
      let functions = case outcome.new_function {
        Some(f) ->
          list.append(list.filter(s.functions, fn(x) { x.0 != f.0 }), [f])
        None -> s.functions
      }
      let types = case outcome.new_type {
        Some(t) -> list.append(list.filter(s.types, fn(x) { x.0 != t.0 }), [t])
        None -> s.types
      }
      Session(..s, bindings:, functions:, types:)
    }
  }
}

fn show_gleam_code(s: Session, gleam: String) -> String {
  case s.colour {
    True -> highlight.gleam(gleam)
    False -> gleam
  }
}

// --- Output ----------------------------------------------------------------------------

/// GSH prints `value : Type` (the type dimmed): shown in Bea syntax and
/// colours.
fn print_value(s: Session, output: String) -> Nil {
  let #(value, type_) = case string.split(output, "\u{001b}[90m : ") {
    [only] -> #(only, "")
    parts -> {
      let assert Ok(last) = list.last(parts)
      let value =
        list.take(parts, list.length(parts) - 1)
        |> string.join("\u{001b}[90m : ")
      #(value, strip_ansi(last))
    }
  }
  let value = gleam_to_bea(string.trim(strip_ansi(value)))
  let type_ = gleam_to_bea(string.trim(type_))
  let paint = painter(s)
  case value, type_ {
    "", "" -> Nil
    "", t -> io.println(paint(style.dim, ": " <> t))
    v, "" -> io.println(show_code(s, v))
    v, t -> io.println(show_code(s, v) <> paint(style.dim, " : " <> t))
  }
}

/// Compile errors are Gleam's, about the generated code; runtime errors
/// are the VM's.
fn print_failure(s: Session, outcome: gsh_result.Evaluation) -> Nil {
  let text = string.trim(strip_ansi(outcome.output))
  let #(first, rest) = case string.split_once(text, "\n") {
    Ok(#(first, rest)) -> #(first, "\n" <> rest)
    Error(_) -> #(text, "")
  }
  let first = case first {
    "error: " <> message -> message
    message -> message
  }
  let first = case outcome.error_kind {
    gsh_result.RuntimeError -> "runtime error: " <> first
    _ -> first
  }
  error(s, first <> rest)
  case outcome.error_kind, s.show_gleam {
    gsh_result.CompileError, False ->
      io.println(painter(s)(
        style.dim,
        "Hint: the error is about the Gleam this input compiles to; :gleam shows it.",
      ))
    _, _ -> Nil
  }
}

/// Gleam's `#(a, b)` tuples are `(a, b)` in Bea.
fn gleam_to_bea(text: String) -> String {
  string.replace(text, "#(", "(")
}

/// A binding's Gleam source as Bea: `let x = 1` -> `x = 1`.
fn binding_to_bea(text: String) -> String {
  case text {
    "let assert " <> rest | "let " <> rest -> gleam_to_bea(rest)
    _ -> gleam_to_bea(text)
  }
}

fn strip_ansi(text: String) -> String {
  let assert Ok(re) = regexp.from_string("\u{001b}\\[[0-9;]*m")
  regexp.replace(re, text, "")
}

/// Bea syntax errors, positioned in what was typed.
fn report(
  s: Session,
  diagnostics: List(diagnostic.Diagnostic),
  input: String,
  offset: Int,
) -> Nil {
  let size = string.byte_size(input)
  diagnostics
  |> list.map(fn(d) {
    let start = int.clamp(d.span.start - offset, 0, size)
    let end = int.clamp(d.span.end - offset, start, size)
    diagnostic.Diagnostic(..d, span: Span(start, end))
  })
  |> diagnostic.render_all_highlighted("shell", input, s.colour, highlight.bea)
  |> io.print
}
