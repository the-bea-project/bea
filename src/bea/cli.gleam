//// The `bea` command line interface.
////
//// Most commands work by syncing the Bea project into its generated Gleam
//// project (`.beabuild/`) and then delegating to the `gleam` executable,
//// translating Gleam's output back to `.bea` locations on the way.

import bea/codegen
import bea/compiler
import bea/diagnostic
import bea/formatter
import bea/gleam_output
import bea/lsp/server as lsp
import bea/project.{type Project}
import bea/system
import gleam/dict
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

pub const version = "0.2.0"

pub fn main(args: List(String)) -> Int {
  case args {
    [] | ["help"] | ["--help"] | ["-h"] -> {
      io.println(help())
      0
    }
    ["--version"] | ["-V"] | ["version"] -> {
      io.println("bea " <> version)
      0
    }
    ["new", ..rest] -> new(rest)
    ["add", ..rest] -> deps_change("add", rest, True)
    ["remove", ..rest] -> deps_change("remove", rest, True)
    ["update", ..rest] -> deps_change("update", rest, False)
    ["deps", ..rest] -> passthrough(["deps", ..rest], False)
    ["clean"] -> clean()
    ["check", ..rest] -> compile_command("check", rest)
    ["build", ..rest] -> compile_command("build", rest)
    ["run", ..rest] -> run(rest)
    ["format", ..rest] | ["fmt", ..rest] -> format(rest)
    ["transpile", ..rest] -> transpile(rest)
    ["export", ..rest] -> passthrough(["export", ..rest], True)
    ["publish", ..rest] -> publish(rest)
    ["hex", ..rest] -> passthrough(["hex", ..rest], False)
    ["lsp", ..] -> lsp.main()
    [command, ..] -> {
      error("Unknown command `" <> command <> "`")
      io.println(help())
      1
    }
  }
}

fn help() -> String {
  "bea " <> version <> " — a friendlier syntax for Gleam

Usage: bea <COMMAND> [OPTIONS]

Project commands:
  new <NAME>           Create a new Bea project
  add <PACKAGE>...     Add dependencies (--dev for dev dependencies)
  remove <PACKAGE>...  Remove dependencies
  update [PACKAGE]...  Update dependencies to their latest compatible versions
  deps <COMMAND>       Work with dependency packages (list, download, tree)
  clean                Delete the generated .beabuild directory

Building:
  check                Type check the project
  build                Build the project
  run [FILE | -m MOD]  Run a module's `main` function (default: the project's)
  export <WHAT>        Export an escript, Erlang shipment, hex tarball, ...

Code:
  format [PATHS]...    Format Bea source files (--check, --stdin)
  transpile [FILE]     Print the Gleam code generated for a file (or
                       --stdin; --out DIR writes the whole project)
  lsp                  Run the language server, to be used by editors

Publishing:
  publish              Publish the package to Hex (as a Gleam package)
  hex <COMMAND>        Hex account commands (authenticate, retire, ...)

Options such as --target are passed through to Gleam.
Run outside a project, `bea run file.bea` treats the file's folder as src/."
}

// --- Output helpers -------------------------------------------------------------

fn colour() -> Bool {
  system.colour()
}

fn error(message: String) -> Nil {
  let prefix = case colour() {
    True -> "\u{001b}[1m\u{001b}[31merror\u{001b}[0m\u{001b}[1m: "
    False -> "error: "
  }
  let suffix = case colour() {
    True -> "\u{001b}[0m"
    False -> ""
  }
  system.print_stderr(prefix <> message <> suffix <> "\n")
}

fn status(verb: String, rest: String) -> Nil {
  let verb = string.pad_start(verb, 11, " ")
  let verb = case colour() {
    True -> "\u{001b}[1m\u{001b}[35m" <> verb <> "\u{001b}[0m"
    False -> verb
  }
  system.print_stderr(verb <> " " <> rest <> "\n")
}

fn print_file_diagnostics(files: List(project.FileErrors)) -> Nil {
  list.each(files, fn(f) {
    system.print_stderr(
      diagnostic.render_all(
        f.diagnostics,
        project.display_path(f.path),
        f.source,
        colour(),
      )
      <> "\n",
    )
  })
}

// --- Projects -------------------------------------------------------------------

fn current_project() -> Result(Project, Nil) {
  case project.find(system.cwd()) {
    Ok(p) -> Ok(p)
    Error(_) -> {
      error(
        "No bea.toml found in this directory or any parent.\n"
        <> "Create a project with `bea new <name>`.",
      )
      Error(Nil)
    }
  }
}

fn gleam() -> Result(String, Nil) {
  case system.gleam_executable() {
    Ok(g) -> Ok(g)
    Error(message) -> {
      error(message)
      Error(Nil)
    }
  }
}

/// Sync sources; prints Bea diagnostics and fails if there are errors.
fn sync(p: Project) -> Result(project.Sync, Nil) {
  let s = project.sync(p, dict.new())
  print_file_diagnostics(s.warnings)
  case s.errors {
    [] -> Ok(s)
    errors -> {
      print_file_diagnostics(errors)
      let n =
        list.fold(errors, 0, fn(acc, f) { acc + list.length(f.diagnostics) })
      error(
        "Bea found "
        <> int.to_string(n)
        <> " error"
        <> case n {
          1 -> ""
          _ -> "s"
        }
        <> " in "
        <> int.to_string(list.length(errors))
        <> " file"
        <> case list.length(errors) {
          1 -> ""
          _ -> "s"
        },
      )
      Error(Nil)
    }
  }
}

/// Run gleam in the build directory, streaming its output through the
/// location rewriter.
fn run_gleam(p: Project, s: project.Sync, args: List(String)) -> Int {
  case gleam() {
    Error(_) -> 1
    Ok(exe) -> {
      let rewriter =
        gleam_output.new(s.modules, p.build_dir, p.src_dir, colour())
      let #(code, rewriter) =
        system.run_lines(exe, args, p.build_dir, rewriter, fn(r, line) {
          let #(r, lines) = gleam_output.feed(r, line)
          list.each(lines, fn(l) { system.print_stderr(l <> "\n") })
          r
        })
      list.each(gleam_output.finish(rewriter), fn(l) {
        system.print_stderr(l <> "\n")
      })
      code
    }
  }
}

fn split_args(args: List(String)) -> #(List(String), List(String)) {
  case list.split_while(args, fn(a) { a != "--" }) {
    #(before, ["--", ..after]) -> #(before, after)
    #(before, _) -> #(before, [])
  }
}

// --- Commands -------------------------------------------------------------------

fn new(args: List(String)) -> Int {
  case list.filter(args, fn(a) { !string.starts_with(a, "-") }) {
    [path] -> {
      let name = string.split(path, "/") |> list.last |> result.unwrap(path)
      case valid_package_name(name) {
        False -> {
          error(
            "`"
            <> name
            <> "` is not a valid project name. Use lowercase letters, digits and underscores, starting with a letter.",
          )
          1
        }
        True ->
          case simplifile.is_directory(path) {
            Ok(True) -> {
              error("`" <> path <> "` already exists")
              1
            }
            _ -> {
              let files = [
                #(
                  "bea.toml",
                  project.default_config(name)
                    |> string.replace(
                      "\n\n[dependencies]",
                      "\n\n# description = \"\"\n# licences = [\"Apache-2.0\"]\n# repository = { type = \"github\", user = \"\", repo = \"\" }\n\n[dependencies]",
                    )
                    |> string.append("\n[dev_dependencies]\n"),
                ),
                #(
                  "src/" <> name <> ".bea",
                  "import gleam/io\n\npub def main() {\n  io.println(\"Hello from "
                    <> name
                    <> "!\")\n}\n",
                ),
                #(
                  "README.md",
                  "# "
                    <> name
                    <> "\n\nA [Bea](https://github.com/) project.\n\n```sh\nbea run   # Run the project\nbea check # Type check the project\n```\n",
                ),
                #(".gitignore", "/.beabuild\n*.beam\n*.ez\nerl_crash.dump\n"),
              ]
              list.each(files, fn(f) {
                let full = path <> "/" <> f.0
                let _ = simplifile.create_directory_all(project.dirname(full))
                let _ = simplifile.write(full, f.1)
                Nil
              })
              io.println(
                "Your Bea project " <> name <> " has been successfully created.",
              )
              io.println(
                "The project can be compiled and run with these commands:\n",
              )
              io.println("    cd " <> path)
              io.println("    bea run\n")
              0
            }
          }
      }
    }
    _ -> {
      error("Usage: bea new <NAME>")
      1
    }
  }
}

fn valid_package_name(name: String) -> Bool {
  case string.to_graphemes(name) {
    [first, ..rest] ->
      string.contains("abcdefghijklmnopqrstuvwxyz", first)
      && list.all(rest, fn(c) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", c)
      })
    [] -> False
  }
}

/// `add`, `remove` and `update` only touch configuration, so they don't need
/// the code to compile.
fn deps_change(
  command: String,
  args: List(String),
  config_changes: Bool,
) -> Int {
  case command, list.filter(args, fn(a) { !string.starts_with(a, "-") }) {
    "add", [] | "remove", [] -> {
      error(
        "Please specify at least one package: `bea "
        <> command
        <> " <PACKAGE>...`",
      )
      1
    }
    _, _ -> {
      use p <- or_exit(current_project())
      use exe <- or_exit(gleam())
      project.sync_config(p)
      let code = system.run_inherit(exe, [command, ..args], p.build_dir)
      project.sync_back(p, config_changes)
      case code, config_changes {
        0, True -> status("Updated", project.config_file)
        _, _ -> Nil
      }
      code
    }
  }
}

fn or_exit(r: Result(a, Nil), next: fn(a) -> Int) -> Int {
  case r {
    Ok(v) -> next(v)
    Error(_) -> 1
  }
}

fn passthrough(args: List(String), needs_sources: Bool) -> Int {
  use p <- or_exit(current_project())
  case needs_sources {
    True -> {
      use s <- or_exit(sync(p))
      let code = run_gleam(p, s, args)
      project.sync_back(p, False)
      case args {
        ["export", ..] if code == 0 ->
          status(
            "Exported",
            "to " <> project.display_path(p.build_dir <> "/build"),
          )
        _ -> Nil
      }
      code
    }
    False -> {
      use exe <- or_exit(gleam())
      project.sync_config(p)
      let code = system.run_inherit(exe, args, p.build_dir)
      project.sync_back(p, False)
      code
    }
  }
}

fn clean() -> Int {
  use p <- or_exit(current_project())
  let _ = simplifile.delete(p.build_dir)
  status("Cleaned", project.display_path(p.build_dir))
  0
}

fn compile_command(command: String, args: List(String)) -> Int {
  use p <- or_exit(current_project())
  use s <- or_exit(sync(p))
  let code = run_gleam(p, s, [command, ..args])
  project.sync_back(p, False)
  code
}

fn run(args: List(String)) -> Int {
  let #(args, program_args) = split_args(args)
  let #(file, module, gleam_args) = parse_run_args(args, None, None, [])
  let resolved = case file {
    Some(f) ->
      case project.find(project.dirname(system.absolute_path(f))) {
        Ok(p) -> Ok(p)
        Error(_) -> Ok(project.script(f))
      }
    None -> current_project()
  }
  use p <- or_exit(resolved)
  let module = case module, file {
    Some(m), _ -> m
    None, Some(f) -> project.module_name(p, system.absolute_path(f))
    None, None -> default_module(p) |> option.unwrap(p.name)
  }
  let #(target, runtime, build_args) = run_target(p, gleam_args)
  use s <- or_exit(sync(p))
  // Build in .beabuild/, then run the program ourselves from the project
  // root (not from .beabuild/ like `gleam run` would), so relative paths,
  // `.env` files & co resolve against the user's project.
  let code = case run_gleam(p, s, ["build", ..build_args]) {
    0 ->
      case system.was_interrupted() {
        // Ctrl+C while building: don't start the program.
        Ok(code) -> code
        Error(_) -> run_program(p, s, target, runtime, module, program_args)
      }
    code -> code
  }
  project.sync_back(p, False)
  code
}

type Target {
  Erlang
  JavaScript
}

/// The compile target and JavaScript runtime for `bea run`, and the
/// arguments to pass on to `gleam build` (which doesn't know `--runtime`).
fn run_target(
  p: Project,
  args: List(String),
) -> #(Target, String, List(String)) {
  let parse_target = fn(t) {
    case t {
      "javascript" | "js" -> JavaScript
      _ -> Erlang
    }
  }
  let #(target, runtime, rest) = collect_run_flags(args, None, None, [])
  let target = case target {
    Some(t) -> parse_target(t)
    None -> parse_target(config_value(p.config, "target") |> option.unwrap(""))
  }
  let runtime = case runtime {
    Some(r) -> r
    None -> config_value(p.config, "runtime") |> option.unwrap("nodejs")
  }
  #(target, runtime, rest)
}

fn collect_run_flags(
  args: List(String),
  target: Option(String),
  runtime: Option(String),
  rest: List(String),
) -> #(Option(String), Option(String), List(String)) {
  case args {
    [] -> #(target, runtime, list.reverse(rest))
    ["--target", t, ..more] | ["-t", t, ..more] ->
      collect_run_flags(more, Some(t), runtime, [t, "--target", ..rest])
    ["--target=" <> t, ..more] ->
      collect_run_flags(more, Some(t), runtime, ["--target=" <> t, ..rest])
    ["--runtime", r, ..more] -> collect_run_flags(more, target, Some(r), rest)
    ["--runtime=" <> r, ..more] ->
      collect_run_flags(more, target, Some(r), rest)
    [a, ..more] -> collect_run_flags(more, target, runtime, [a, ..rest])
  }
}

/// A `key = "value"` from the configuration (top-level keys only).
fn config_value(config: String, key: String) -> Option(String) {
  config
  |> string.split("\n")
  |> list.take_while(fn(line) { !string.starts_with(string.trim(line), "[") })
  |> list.find_map(fn(line) {
    case string.split_once(line, "=") {
      Ok(#(k, v)) if k != "" ->
        case string.trim(k) == key {
          True ->
            case string.trim(v) {
              "\"" <> quoted ->
                string.split_once(quoted, "\"")
                |> result.map(fn(parts) { parts.0 })
              bare ->
                Ok(
                  string.split_once(bare, "#")
                  |> result.map(fn(parts) { string.trim(parts.0) })
                  |> result.unwrap(bare),
                )
            }
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
  |> option.from_result
}

/// Run `main` of a built module, the way `gleam run` does: on Erlang through
/// the `<package>@@main` entrypoint Gleam generates (it starts the
/// application so `application:get_key/2` & co work, and prints panics
/// nicely), on JavaScript through a small entry module.
fn run_program(
  p: Project,
  s: project.Sync,
  target: Target,
  runtime: String,
  module: String,
  program_args: List(String),
) -> Int {
  let rewriter = gleam_output.new(s.modules, p.build_dir, p.src_dir, colour())
  let command = case target {
    Erlang -> {
      let lib = p.build_dir <> "/build/dev/erlang"
      let ebin =
        simplifile.read_directory(lib)
        |> result.unwrap([])
        |> list.sort(string.compare)
        |> list.filter_map(fn(dir) {
          let path = lib <> "/" <> dir <> "/ebin"
          case simplifile.is_directory(path) {
            Ok(True) -> Ok(["-pa", path])
            _ -> Error(Nil)
          }
        })
        |> list.flatten
      let erlang_module = string.replace(module, "/", "@")
      Ok(#(
        "erl",
        list.flatten([
          ebin,
          [
            // No BREAK menu if a Ctrl+C reaches the program: just stop.
            "+Bd",
            "-eval",
            "'" <> p.name <> "@@main':run('" <> erlang_module <> "')",
            "-noshell",
            "-extra",
          ],
          program_args,
        ]),
      ))
    }
    JavaScript -> {
      let dir = p.build_dir <> "/build/dev/javascript/" <> p.name
      let entry = dir <> "/bea@@main.mjs"
      project.write_if_changed(
        entry,
        "import { main } from \"./" <> module <> ".mjs\";\nmain();\n",
      )
      case runtime {
        "deno" -> Ok(#("deno", ["run", "--allow-all", entry, ..program_args]))
        "bun" -> Ok(#("bun", ["run", entry, ..program_args]))
        _ -> Ok(#("node", [entry, ..program_args]))
      }
    }
  }
  let found =
    result.try(command, fn(c) {
      case system.find_executable(c.0) {
        Ok(exe) -> Ok(#(exe, c.1))
        Error(_) -> Error("`" <> c.0 <> "` was not found on your PATH")
      }
    })
  case found {
    Error(message) -> {
      error(message)
      1
    }
    Ok(#(exe, args)) -> {
      let #(code, rewriter) =
        system.run_stderr_lines(exe, args, p.root, rewriter, fn(r, line) {
          let #(r, lines) = gleam_output.feed(r, line)
          list.each(lines, fn(l) { system.print_stderr(l <> "\n") })
          r
        })
      list.each(gleam_output.finish(rewriter), fn(l) {
        system.print_stderr(l <> "\n")
      })
      code
    }
  }
}

fn parse_run_args(
  args: List(String),
  file: Option(String),
  module: Option(String),
  rest: List(String),
) -> #(Option(String), Option(String), List(String)) {
  case args {
    [] -> #(file, module, list.reverse(rest))
    ["-m", m, ..more] | ["--module", m, ..more] ->
      parse_run_args(more, file, Some(m), rest)
    [".", ..more] -> parse_run_args(more, file, module, rest)
    [a, ..more] ->
      case string.ends_with(a, ".bea") {
        True -> parse_run_args(more, Some(a), module, rest)
        False -> parse_run_args(more, file, module, [a, ..rest])
      }
  }
}

/// Gleam runs the module named after the package; for compatibility with
/// earlier Bea projects we also accept `src/main.bea`.
fn default_module(p: Project) -> Option(String) {
  let has = fn(name) {
    result.unwrap(simplifile.is_file(p.src_dir <> "/" <> name <> ".bea"), False)
    || result.unwrap(
      simplifile.is_file(p.src_dir <> "/" <> name <> ".gleam"),
      False,
    )
  }
  case has(p.name), has("main") {
    True, _ -> None
    False, True -> Some("main")
    False, False -> None
  }
}

fn format(args: List(String)) -> Int {
  let check = list.contains(args, "--check")
  let stdin = list.contains(args, "--stdin")
  let paths = list.filter(args, fn(a) { !string.starts_with(a, "--") })
  case stdin {
    True -> {
      let source = system.read_stdin()
      case formatter.format(source) {
        Ok(formatted) -> {
          system.print(formatted)
          case check && formatted != source {
            True -> 1
            False -> 0
          }
        }
        Error(diags) -> {
          system.print_stderr(diagnostic.render_all(
            diags,
            "<stdin>",
            source,
            colour(),
          ))
          1
        }
      }
    }
    False -> {
      let paths = case paths {
        [] ->
          case project.find(system.cwd()) {
            Ok(p) -> [p.src_dir]
            Error(_) -> ["."]
          }
        _ -> paths
      }
      let files =
        list.flat_map(paths, fn(path) {
          case simplifile.is_directory(path) {
            Ok(True) ->
              project.source_files(path)
              |> list.filter(fn(f) { string.ends_with(f, ".bea") })
            _ -> [path]
          }
        })
      let results =
        list.map(files, fn(file) {
          case simplifile.read(file) {
            Error(_) -> {
              error("Could not read " <> file)
              #(file, False, True)
            }
            Ok(source) ->
              case formatter.format(source) {
                Error(diags) -> {
                  system.print_stderr(diagnostic.render_all(
                    diags,
                    project.display_path(file),
                    source,
                    colour(),
                  ))
                  #(file, False, True)
                }
                Ok(formatted) if formatted == source -> #(file, False, False)
                Ok(formatted) -> {
                  case check {
                    True -> Nil
                    False -> {
                      let _ = simplifile.write(file, formatted)
                      Nil
                    }
                  }
                  #(file, True, False)
                }
              }
          }
        })
      let failed = list.any(results, fn(r) { r.2 })
      let changed = list.filter(results, fn(r) { r.1 })
      case check, changed {
        True, [_, ..] -> {
          error("These files have not been formatted:\n")
          list.each(changed, fn(r) {
            system.print_stderr("  - " <> project.display_path(r.0) <> "\n")
          })
          1
        }
        _, _ ->
          case failed {
            True -> 1
            False -> 0
          }
      }
    }
  }
}

/// Show the Gleam generated for a file, or write the whole generated
/// project somewhere (an "eject" to plain Gleam).
fn transpile(args: List(String)) -> Int {
  case args {
    ["--out", dir] -> {
      use p <- or_exit(current_project())
      use s <- or_exit(sync(p))
      let _ = s
      let _ = simplifile.create_directory_all(dir)
      let _ = simplifile.copy_directory(p.build_dir <> "/src", dir <> "/src")
      let _ =
        simplifile.copy_file(p.build_dir <> "/gleam.toml", dir <> "/gleam.toml")
      let _ =
        simplifile.copy_file(
          p.build_dir <> "/manifest.toml",
          dir <> "/manifest.toml",
        )
      case gleam() {
        Ok(exe) -> {
          let _ =
            system.run_lines(exe, ["format", "src"], dir, Nil, fn(_, _) { Nil })
          Nil
        }
        Error(_) -> Nil
      }
      status("Wrote", dir)
      0
    }
    ["--stdin"] -> transpile_source(system.read_stdin(), "<stdin>")
    [file] ->
      case simplifile.read(file) {
        Error(_) -> {
          error("Could not read " <> file)
          1
        }
        Ok(source) -> transpile_source(source, file)
      }
    _ -> {
      error(
        "Usage: bea transpile <FILE.bea> | bea transpile --stdin | bea transpile --out <DIR>",
      )
      1
    }
  }
}

fn transpile_source(source: String, name: String) -> Int {
  case compiler.compile(source, codegen.empty_context()) {
    Ok(c) -> {
      io.print(c.gleam)
      0
    }
    Error(diags) -> {
      system.print_stderr(diagnostic.render_all(diags, name, source, colour()))
      1
    }
  }
}

/// Bea packages are published to Hex as the Gleam code they compile to, so
/// both Gleam and Bea projects can depend on them.
fn publish(args: List(String)) -> Int {
  use p <- or_exit(current_project())
  use _ <- or_exit(sync(p))
  use exe <- or_exit(gleam())
  [
    "README.md",
    "README",
    "LICENSE",
    "LICENCE",
    "LICENSE.md",
    "LICENCE.md",
    "LICENSE.txt",
    "CHANGELOG.md",
  ]
  |> list.each(fn(f) {
    case simplifile.read(p.root <> "/" <> f) {
      Ok(content) -> {
        project.write_if_changed(p.build_dir <> "/" <> f, content)
        Nil
      }
      Error(_) -> Nil
    }
  })
  status("Publishing", p.name <> " (as Gleam code generated from Bea)")
  let code = system.run_inherit(exe, ["publish", ..args], p.build_dir)
  project.sync_back(p, False)
  code
}
