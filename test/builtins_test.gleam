//// The built-in modules (bea/builtins): the JSON derivers, written into the
//// generated project when a Bea module imports them.
//// scripts/test_examples.sh builds and runs test_projects/deriving with them.

import bea/builtins
import bea/codegen
import bea/compiler
import bea/project
import bea/system
import gleam/dict
import gleam/list
import gleam/string
import simplifile

const with_json = "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0 and < 2.0.0\"\ngleam_json = \">= 3.0.0 and < 4.0.0\"\n"

const uses_json = "import bea_json/decoder
import bea_json/encoder

@derive(decoder, encoder)
pub type User { name: String, age: Int }

pub def main() {
  decoder.from_json(\"{}\", User.decoder())
}
"

fn fresh_project(
  name: String,
  config: String,
  source: String,
) -> project.Project {
  let root = system.absolute_path("build/bea_test_projects/" <> name)
  let _ = simplifile.delete(root)
  let assert Ok(_) = simplifile.create_directory_all(root <> "/src")
  let assert Ok(_) = simplifile.write(root <> "/bea.toml", config)
  let assert Ok(_) = simplifile.write(root <> "/src/app.bea", source)
  let assert Ok(p) = project.find(root)
  p
}

fn built(p: project.Project, module: String) -> Result(String, Nil) {
  simplifile.read(p.build_dir <> "/src/" <> module <> ".gleam")
  |> result_nil
}

fn result_nil(r: Result(a, e)) -> Result(a, Nil) {
  case r {
    Ok(x) -> Ok(x)
    Error(_) -> Error(Nil)
  }
}

pub fn builtin_modules_compile_cleanly_test() {
  list.each(builtins.modules(), fn(m) {
    let #(name, source) = m
    let assert Ok(compiled) = compiler.compile(source, codegen.empty_context())
      as name
    assert compiled.warnings == []
  })
}

pub fn imported_builtins_are_written_test() {
  let p = fresh_project("builtins_written", with_json, uses_json)
  let sync = project.sync(p, dict.new())
  assert sync.errors == []
  let assert Ok(decoder) = built(p, "bea_json/decoder")
  assert string.contains(decoder, "pub fn record(")
  let assert Ok(encoder) = built(p, "bea_json/encoder")
  assert string.contains(encoder, "pub fn to_string(")
  let written =
    list.map(sync.written, string.drop_start(_, string.length(p.build_dir) + 1))
  assert list.contains(written, "src/bea_json/decoder.gleam")
  // Unchanged on the next sync, so not written again.
  let again = project.sync(p, dict.new())
  assert again.written == []
}

pub fn unused_builtins_are_not_written_test() {
  let p =
    fresh_project("builtins_unused", with_json, "pub def main() {\n  Nil\n}\n")
  let sync = project.sync(p, dict.new())
  assert sync.errors == []
  assert built(p, "bea_json/decoder") == Error(Nil)
  // And removed once nothing imports them.
  let p = fresh_project("builtins_removed", with_json, uses_json)
  let _ = project.sync(p, dict.new())
  let assert Ok(_) =
    simplifile.write(p.src_dir <> "/app.bea", "pub def main() {\n  Nil\n}\n")
  let _ = project.sync(p, dict.new())
  assert built(p, "bea_json/decoder") == Error(Nil)
}

pub fn the_projects_own_module_wins_test() {
  let p = fresh_project("builtins_own", with_json, uses_json)
  let assert Ok(_) = simplifile.create_directory_all(p.src_dir <> "/bea_json")
  let own = "pub fn mine() {\n  1\n}\n"
  let assert Ok(_) =
    simplifile.write(p.src_dir <> "/bea_json/decoder.gleam", own)
  let _ = project.sync(p, dict.new())
  assert built(p, "bea_json/decoder") == Ok(own)
}

pub fn missing_gleam_json_is_reported_on_the_imports_test() {
  let p =
    fresh_project("builtins_no_json", project.default_config("app"), uses_json)
  let sync = project.sync(p, dict.new())
  let assert [file] = sync.errors
  assert string.ends_with(file.path, "src/app.bea")
  assert list.map(file.diagnostics, fn(d) { d.title })
    == ["Missing dependency", "Missing dependency"]
  // In source order: the decoder's import first.
  let assert [first, ..] = file.diagnostics
  assert first.span.start == 0
  assert built(p, "bea_json/decoder") == Error(Nil)
}

pub fn depends_on_reads_the_dependencies_section_test() {
  assert project.depends_on(with_json, "gleam_json")
  assert !project.depends_on(project.default_config("app"), "gleam_json")
  // A dev dependency can't be imported from src/.
  assert !project.depends_on(
    "name = \"a\"\n[dev_dependencies]\ngleam_json = \"1.0.0\"\n",
    "gleam_json",
  )
  assert project.depends_on(
    "[dependencies]\n\"gleam_json\" = { version = \">= 3.0.0\" }\n",
    "gleam_json",
  )
  assert !project.depends_on(
    "[dependencies]\ngleam_json_extra = \"1.0.0\"\n",
    "gleam_json",
  )
}
