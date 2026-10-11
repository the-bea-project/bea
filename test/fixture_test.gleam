import bea/codegen
import bea/lexer
import bea/parser
import gleam/list
import gleam/string
import gleeunit/should
import simplifile

pub fn all_fixtures_test() {
  // 1. Read the fixtures directory
  let assert Ok(files) = simplifile.read_directory("test/fixtures")

  // 2. Filter for only the .bea files
  let bea_files =
    files
    |> list.filter(fn(file) { string.ends_with(file, ".bea") })

  // 3. Loop through each .bea file and test it against its .gleam pair
  list.each(bea_files, fn(bea_file) {
    let base_name = string.replace(bea_file, ".bea", "")
    let gleam_file = base_name <> ".gleam"

    let bea_path = "test/fixtures/" <> bea_file
    let gleam_path = "test/fixtures/" <> gleam_file

    // Read the source and the expected output
    let assert Ok(source) = simplifile.read(bea_path)
    let assert Ok(expected) = simplifile.read(gleam_path)

    // Transpile the Bea source
    let output =
      source
      |> lexer.tokenize()
      |> parser.parse()
      |> codegen.generate()

    // Assert they match (trimming whitespace to ignore editor trailing newlines)
    string.trim(output)
    |> should.equal(string.trim(expected))
  })
}
