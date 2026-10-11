// src/bea.gleam

import argv
import bea/codegen
import bea/lexer
import bea/parser
import gleam/io
import gleam/list
import gleam/result
import gleam/set.{type Set}
import gleam/string
import shellout
import simplifile

pub fn main() {
  case argv.load().arguments {
    ["transpile", target] -> {
      let root_module = setup_project(target)
      io.println("Transpiled project tree starting at " <> root_module)
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

          // Look for the file in the base directory instead of hardcoded "src/"
          let filepath = base_dir <> "/" <> module <> ".bea"

          let source = case simplifile.read(filepath) {
            Ok(s) -> s
            Error(_) -> panic as { "Could not find module: " <> filepath }
          }

          let new_imports = extract_imports(source)
          let new_queue = list.append(rest, new_imports)

          let gleam_code =
            source
            |> lexer.tokenize()
            |> parser.parse()
            |> codegen.generate()

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
      }
    }
  }
}

// Scans text directly for "import my_module"
fn extract_imports(source: String) -> List(String) {
  source
  |> string.split("\n")
  |> list.map(string.trim)
  |> list.filter(string.starts_with(_, "import "))
  |> list.map(fn(line) {
    line
    |> string.replace("import ", "")
    |> string.trim()
  })
}
