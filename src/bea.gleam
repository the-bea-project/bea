// src/bea.gleam

import argv
import bea/codegen
import bea/lexer
import bea/parser
import gleam/io
import gleam/string
import simplifile

pub fn main() {
  case argv.load().arguments {
    ["build", filepath] -> build_file(filepath)
    _ -> io.println("Usage: gleam run build <filepath.bea>")
  }
}

fn build_file(filepath: String) {
  // 1. Ensure it's a .bea file
  let _ = case !string.ends_with(filepath, ".bea") {
    True -> {
      io.println("Error: Can only build .bea files")
      panic as "Invalid file extension"
    }
    False -> Ok(Nil)
  }
  // 2. Read the source code
  let source_result = simplifile.read(filepath)
  case source_result {
    Ok(source) -> {
      // 3. Run our transpiler pipeline!
      let gleam_code =
        source
        |> lexer.tokenize()
        |> parser.parse()
        |> codegen.generate()

      // 4. Determine output path (replace .bea with .gleam)
      let out_path = string.replace(filepath, ".bea", ".gleam")

      // 5. Write the generated code to disk
      let write_result = simplifile.write(out_path, gleam_code)
      case write_result {
        Ok(_) ->
          io.println("Success! Compiled " <> filepath <> " to " <> out_path)
        Error(_) -> io.println("Error: Failed to write output file.")
      }
    }
    Error(_) -> io.println("Error: Could not read file " <> filepath)
  }
}
