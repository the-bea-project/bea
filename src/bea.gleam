// src/bea.gleam

import argv
import bea/ast
import bea/codegen
import bea/desugar
import bea/lexer
import bea/parser
import gleam/io
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import shellout
import simplifile

pub type LocalImport {
  BeaFile(String)
  GleamFile(String)
  ExternalPackage
}

pub fn main() {
  case argv.load().arguments {
    ["transpile", target] -> {
      let root_module = setup_project(target)
      io.println(
        green("Transpiled project tree starting at: ") <> bold(root_module),
      )
    }

    // Scaffold a new project!
    ["new", project_name] -> {
      let src_dir = project_name <> "/src"
      let assert Ok(_) = simplifile.create_directory_all(src_dir)

      let toml =
        "name = \""
        <> project_name
        <> "\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.34.0 and < 2.0.0\"\n"
      let assert Ok(_) = simplifile.write(project_name <> "/bea.toml", toml)

      // Clean, simple Bea code without the io import
      let initial_code =
        "pub def main() {\n  echo \"Hello from " <> project_name <> "!\"\n}\n"
      let assert Ok(_) = simplifile.write(src_dir <> "/main.bea", initial_code)

      io.println(green("Created new Bea project: ") <> bold(project_name))
      io.println(cyan("   cd ") <> project_name)
      io.println(cyan("   bea run ."))
    }

    ["check", target] -> {
      let _ = setup_project(target)
      io.println(cyan("Checking project via Gleam..."))
      let result = shellout.command("gleam", ["check"], ".beabuild", [])
      case result {
        Ok(output) -> io.print(output)
        Error(#(_code, err_msg)) -> io.println(red(err_msg))
      }
    }

    ["build", target] -> {
      let _ = setup_project(target)
      io.println(cyan("Building project via Gleam..."))
      let result = shellout.command("gleam", ["build"], ".beabuild", [])
      case result {
        Ok(output) -> io.print(output)
        Error(#(_code, err_msg)) -> io.println(red(err_msg))
      }
    }

    // Go-like ergonomics: `bea run` or `bea run .` defaults to src/main.bea
    ["run"] | ["run", "."] -> run_project("src/main.bea")
    ["run", target] -> run_project(target)

    ["add", ..packages] -> {
      case packages {
        [] ->
          io.println(red("Error: Please specify at least one package to add."))
        _ -> {
          let _ = setup_project("main.bea")

          let pkg_str = string.join(packages, ", ")
          io.println(
            cyan("Resolving packages '")
            <> bold(pkg_str)
            <> cyan("' via Hex..."),
          )

          // Build the command arguments: ["add", "gsh", "simplifile", "glam"]
          let args = list.append(["add"], packages)
          let result = shellout.command("gleam", args, ".beabuild", [])

          case result {
            Ok(output) -> {
              io.print(output)
              let assert Ok(_) =
                simplifile.copy_file(".beabuild/gleam.toml", "bea.toml")
              io.println(green("Updated bea.toml successfully!"))
            }
            Error(#(_code, err_msg)) -> io.println(red(err_msg))
          }
        }
      }
    }

    _ ->
      io.println(
        "Usage: bea [new | transpile | build | run | add] <. | filepath.bea>",
      )
  }
}

fn setup_project(target: String) -> String {
  let build_dir = ".beabuild"
  let src_dir = build_dir <> "/src"
  let _ = simplifile.delete(src_dir)

  let assert Ok(_) = simplifile.create_directory_all(src_dir)

  let toml = case simplifile.read("bea.toml") {
    Ok(contents) -> contents
    Error(_) -> {
      io.println(cyan("Warning: No bea.toml found. Using default manifest."))
      "name = \"bea_app\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.34.0 and < 2.0.0\"\n"
    }
  }

  let assert Ok(_) = simplifile.write(build_dir <> "/gleam.toml", toml)

  case string.ends_with(target, ".bea") {
    False -> panic as { "Error: Expected a .bea file, got: " <> target }
    True -> Nil
  }

  let root_module =
    target
    |> string.split("/")
    |> list.last()
    |> result.unwrap("main.bea")
    |> string.replace(".bea", "")

  let base_dir =
    target
    |> string.split("/")
    |> list.reverse()
    |> list.drop(1)
    |> list.reverse()
    |> string.join("/")

  let base_dir = case base_dir {
    "" -> "."
    path -> path
  }

  crawl_and_transpile([root_module], set.new(), src_dir, base_dir)

  root_module
}

fn crawl_and_transpile(
  queue: List(String),
  visited: Set(String),
  out_dir: String,
  base_dir: String,
) {
  case queue {
    [] -> Nil
    [module, ..rest] -> {
      case set.contains(visited, module) {
        True -> crawl_and_transpile(rest, visited, out_dir, base_dir)
        False -> {
          let new_visited = set.insert(visited, module)

          case resolve_import(module, base_dir) {
            BeaFile(_) -> {
              let filepath = base_dir <> "/" <> module <> ".bea"

              let source = case simplifile.read(filepath) {
                Ok(s) -> s
                Error(_) -> panic as { "Could not find module: " <> filepath }
              }

              let parsed_ast =
                source
                |> lexer.tokenize()
                |> parser.parse()

              let desugared_ast = desugar.process(parsed_ast)

              let local_imports =
                desugared_ast
                |> extract_imports_from_ast()
                |> list.filter(fn(imp) {
                  case resolve_import(imp, base_dir) {
                    BeaFile(_) | GleamFile(_) -> True
                    ExternalPackage -> False
                  }
                })

              let new_queue = list.append(rest, local_imports)
              let gleam_code = codegen.generate(desugared_ast)
              let out_path = out_dir <> "/" <> module <> ".gleam"

              let out_folder =
                string.split(out_path, "/")
                |> list.reverse()
                |> list.drop(1)
                |> list.reverse()
                |> string.join("/")

              let assert Ok(_) = simplifile.create_directory_all(out_folder)
              let assert Ok(_) = simplifile.write(out_path, gleam_code)

              crawl_and_transpile(new_queue, new_visited, out_dir, base_dir)
            }

            GleamFile(_) -> {
              let src_path = base_dir <> "/" <> module <> ".gleam"
              let out_path = out_dir <> "/" <> module <> ".gleam"

              let out_folder =
                string.split(out_path, "/")
                |> list.reverse()
                |> list.drop(1)
                |> list.reverse()
                |> string.join("/")

              let assert Ok(_) = simplifile.create_directory_all(out_folder)
              let assert Ok(_) = simplifile.copy_file(src_path, out_path)

              crawl_and_transpile(rest, new_visited, out_dir, base_dir)
            }

            ExternalPackage -> {
              crawl_and_transpile(rest, new_visited, out_dir, base_dir)
            }
          }
        }
      }
    }
  }
}

fn extract_imports_from_ast(program: ast.Program) -> List(String) {
  let ast.Program(statements) = program
  list.filter_map(statements, fn(stmt) {
    case stmt {
      ast.ImportStmt(path) -> Ok(path)
      _ -> Error(Nil)
    }
  })
}

fn resolve_import(import_path: String, base_dir: String) -> LocalImport {
  case string.starts_with(import_path, "gleam/") {
    True -> ExternalPackage
    False -> {
      let bea_path = base_dir <> "/" <> import_path <> ".bea"
      let gleam_path = base_dir <> "/" <> import_path <> ".gleam"

      case simplifile.is_file(bea_path) {
        Ok(True) -> BeaFile(import_path)
        _ -> {
          case simplifile.is_file(gleam_path) {
            Ok(True) -> GleamFile(import_path)
            _ -> ExternalPackage
          }
        }
      }
    }
  }
}

fn run_project(target: String) {
  let root_module = setup_project(target)
  io.println(green("Running ") <> bold(root_module) <> green("...\n"))

  // 1. Build the code inside the hidden directory
  let build_result = shellout.command("gleam", ["build"], ".beabuild", [])

  case build_result {
    Error(#(_code, err_msg)) -> io.println(red(err_msg))
    Ok(_) -> {
      // 2. Extract all the compiled Erlang bin paths from the build directory
      let ebin_paths =
        simplifile.read_directory(".beabuild/build/dev/erlang")
        |> result.unwrap([])
        |> list.map(fn(dir) { ".beabuild/build/dev/erlang/" <> dir <> "/ebin" })

      let pa_args = list.flat_map(ebin_paths, fn(path) { ["-pa", path] })

      // 3. Command the Erlang VM to execute the target module's main function
      let eval_str = root_module <> ":main(), init:stop()."
      let args = list.append(pa_args, ["-noshell", "-eval", eval_str])

      // 4. Run the compiled code from the PROJECT ROOT (CWD = ".")
      let run_result = shellout.command("erl", args, ".", [])

      case run_result {
        Ok(output) -> io.print(output)
        Error(#(_code, err_msg)) -> io.println(red(err_msg))
      }
    }
  }
}

// --- Terminal Color Helpers ---

fn green(text: String) -> String {
  "\u{001b}[32m" <> text <> "\u{001b}[0m"
}

fn cyan(text: String) -> String {
  "\u{001b}[36m" <> text <> "\u{001b}[0m"
}

fn bold(text: String) -> String {
  "\u{001b}[1m" <> text <> "\u{001b}[0m"
}

fn red(text: String) -> String {
  "\u{001b}[31m" <> text <> "\u{001b}[0m"
}
