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
      io.println("Transpiled project tree starting at " <> root_module)
    }

    ["check", target] -> {
      let _ = setup_project(target)
      io.println("Checking project via Gleam...")
      let result = shellout.command("gleam", ["check"], ".beabuild", [])
      case result {
        Ok(output) -> io.print(output)
        Error(#(_code, err_msg)) -> io.println(err_msg)
      }
    }

    ["build", target] -> {
      let _ = setup_project(target)
      io.println("Building project via Gleam...")
      let result = shellout.command("gleam", ["build"], ".beabuild", [])
      case result {
        Ok(output) -> io.print(output)
        Error(#(_code, err_msg)) -> io.println(err_msg)
      }
    }

    ["run", target] -> {
      let root_module = setup_project(target)
      io.println("Running " <> root_module <> "...\n")

      let result =
        shellout.command("gleam", ["run", "-m", root_module], ".beabuild", [])
      case result {
        Ok(output) -> io.print(output)
        Error(#(_code, err_msg)) -> io.println(err_msg)
      }
    }

    _ -> io.println("Usage: bea [transpile | build | run] <. | filepath.bea>")
  }
}

fn setup_project(target: String) -> String {
  let build_dir = ".beabuild"
  let src_dir = build_dir <> "/src"
  let _ = simplifile.delete(src_dir)

  let assert Ok(_) = simplifile.create_directory_all(src_dir)

  let toml =
    "name = \"bea_app\"\nversion = \"0.1.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.34.0 and < 2.0.0\"\n"
  let assert Ok(_) = simplifile.write(build_dir <> "/gleam.toml", toml)

  let _ = case !string.ends_with(target, ".bea") {
    True -> panic as "Error: Target must be a .bea file"
    False -> Ok(Nil)
  }

  // Extract the filename as the root module ("path/to/script.bea" -> "script")
  let root_module =
    target
    |> string.split("/")
    |> list.last()
    |> result.unwrap("main.bea")
    |> string.replace(".bea", "")

  // Extract the base directory to resolve imports relative to the target file
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

  // Pass base_dir to the crawler
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
            // 1. Local .bea file -> Transpile to Gleam
            BeaFile(_) -> {
              let filepath = base_dir <> "/" <> module <> ".bea"

              let source = case simplifile.read(filepath) {
                Ok(s) -> s
                Error(_) -> panic as { "Could not find module: " <> filepath }
              }

              // Lex and Parse
              let parsed_ast =
                source
                |> lexer.tokenize()
                |> parser.parse()

              // Run the Desugaring Pass
              let desugared_ast = desugar.process(parsed_ast)

              // Filter imports to queue local (.bea or .gleam) dependencies
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

            // 2. Local .gleam file -> Copy straight over
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

            // 3. Stdlib or Hex Package -> Skip file crawling
            ExternalPackage -> {
              crawl_and_transpile(rest, new_visited, out_dir, base_dir)
            }
          }
        }
      }
    }
  }
}

// Extracts import paths directly from the parsed AST
fn extract_imports_from_ast(program: ast.Program) -> List(String) {
  let ast.Program(statements) = program
  list.filter_map(statements, fn(stmt) {
    case stmt {
      ast.ImportStmt(path) -> Ok(path)
      _ -> Error(Nil)
    }
  })
}

// Determines whether an import path maps to a local `.bea`, `.gleam`, or external package
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
