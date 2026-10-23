//// Gleam modules living in a Bea project's src/: hand written, or generated
//// by a tool such as Marmot (src/generated/sql/*.gleam).

import bea/codegen
import bea/project
import bea/system
import gleam/dict
import gleam/set
import gleam/string
import simplifile

fn singles(source: String) -> List(String) {
  codegen.gleam_single_constructors(source) |> set.to_list
}

pub fn single_constructor_types_test() {
  let source =
    "import gleam/dynamic/decode
import sqlight

/// Generated from src/users/sql/find_user.sql
pub type FindUserRow {
  FindUserRow(id: Int, username: String, email: Option(String))
}

pub type Status {
  Active
  Banned(reason: String)
}

pub fn find_user(
  db db: sqlight.Connection,
  username username: String,
) -> Result(List(FindUserRow), sqlight.Error) {
  let decoder = {
    use id <- decode.field(0, decode.int)
    decode.success(FindUserRow(id:, username: \"\", email: None))
  }
  todo
}
"
  assert singles(source) == ["FindUserRow"]
}

pub fn fields_on_their_own_lines_test() {
  // Capitalised field types are inside the parentheses: not constructors.
  let source =
    "pub type Row {
  Row(
    String,
    Int,
    labelled: List(Dict(String, Int)),
  )
}
"
  assert singles(source) == ["Row"]
}

pub fn parameters_and_attributes_test() {
  let source =
    "@internal
pub type Pair(a, b) {
  /// The only one.
  @deprecated(\"Use Other\")
  Pair(first: a, second: b)
}
"
  assert singles(source) == ["Pair"]
}

pub fn types_that_are_not_single_constructor_test() {
  // Opaque and private types aren't usable from other modules; aliases and
  // external types have no constructors.
  let source =
    "pub opaque type Secret {
  Secret(value: String)
}

type Private {
  Private
}

pub type Alias =
  List(Int)

pub type External

pub type Two { A B }

pub type One { One }
"
  assert singles(source) == ["One"]
}

pub fn unreadable_source_reports_nothing_test() {
  // When in doubt, say nothing: a wrong answer would not compile.
  assert singles("pub type Row {\n  Row(x: Int)\n}\n\"unterminated") == []
  assert singles("pub type Row {\n  Row(x: Int)\n") == []
}

// --- Mixed projects ----------------------------------------------------------------

fn fresh_project(name: String) -> project.Project {
  let root = system.absolute_path("build/bea_test_projects/" <> name)
  let _ = simplifile.delete(root)
  let assert Ok(_) =
    simplifile.create_directory_all(root <> "/src/generated/sql")
  let assert Ok(_) =
    simplifile.write(root <> "/bea.toml", project.default_config(name))
  let assert Ok(p) = project.find(root)
  p
}

const generated = "pub type GreetingRow {
  GreetingRow(id: Int, text: String)
}

pub fn find_greeting(db db: String, id id: Int) -> Result(List(GreetingRow), String) {
  case id {
    1 -> Ok([GreetingRow(id: 1, text: \"hello from \" <> db)])
    _ -> Error(\"no greeting\")
  }
}
"

const app = "import generated/sql/example_sql.{GreetingRow}

pub def greeting() -> String {
  Ok([row]) = example_sql.find_greeting(db: \"dev.sqlite\", id: 1) else \"none\"
  GreetingRow(text:, ..) = row
  text
}
"

pub fn generated_gleam_modules_compile_with_bea_modules_test() {
  let p = fresh_project("mixed")
  let generated_path = p.src_dir <> "/generated/sql/example_sql.gleam"
  let assert Ok(_) = simplifile.write(generated_path, generated)
  let assert Ok(_) = simplifile.write(p.src_dir <> "/mixed.bea", app)

  let s = project.sync(p, dict.new())
  assert s.errors == []
  // Code generation knows the generated module's record type, so the
  // pattern that can't fail is a `let` (a `let assert` would make Gleam warn
  // about a redundant assertion at the user's Bea code).
  assert dict.get(s.context.single_constructors, "generated/sql/example_sql")
    == Ok(set.from_list(["GreetingRow"]))
  let assert Ok(out) = simplifile.read(p.build_dir <> "/src/mixed.gleam")
  assert string.contains(out, "let GreetingRow(text: text, ..) = row")
  assert !string.contains(out, "let assert GreetingRow")

  // The generated module is used in place and copied into the build.
  let copy = p.build_dir <> "/src/generated/sql/example_sql.gleam"
  assert simplifile.read(copy) == Ok(generated)
  assert simplifile.read(generated_path) == Ok(generated)

  // Syncing again never touches the original.
  let _ = project.sync(p, dict.new())
  let _ = project.sync(p, dict.new())
  assert simplifile.read(generated_path) == Ok(generated)
  assert simplifile.read(copy) == Ok(generated)
}

pub fn regenerated_and_removed_modules_are_not_stale_test() {
  let p = fresh_project("regenerated")
  let generated_path = p.src_dir <> "/generated/sql/example_sql.gleam"
  let copy = p.build_dir <> "/src/generated/sql/example_sql.gleam"
  let assert Ok(_) = simplifile.write(generated_path, generated)
  let assert Ok(_) = simplifile.write(p.src_dir <> "/regenerated.bea", app)
  let #(_, cache) = project.sync_cached(p, dict.new(), project.new_cache())

  // The tool regenerates the module: now `GreetingRow` has a sibling, so
  // the pattern can fail and must be a `let assert` again.
  let regenerated =
    string.replace(
      generated,
      "  GreetingRow(id: Int, text: String)\n",
      "  GreetingRow(id: Int, text: String)\n  NoGreeting\n",
    )
  let assert Ok(_) = simplifile.write(generated_path, regenerated)
  let #(s, cache) = project.sync_cached(p, dict.new(), cache)
  assert simplifile.read(copy) == Ok(regenerated)
  assert dict.get(s.context.single_constructors, "generated/sql/example_sql")
    == Error(Nil)
  let assert Ok(out) = simplifile.read(p.build_dir <> "/src/regenerated.gleam")
  assert string.contains(out, "let assert GreetingRow(text: text, ..) = row")

  // The tool removes the module: so does the build.
  let assert Ok(_) = simplifile.delete(generated_path)
  let _ = project.sync_cached(p, dict.new(), cache)
  assert simplifile.is_file(copy) == Ok(False)
}
