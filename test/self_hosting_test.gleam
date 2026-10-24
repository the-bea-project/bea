//// Bea's compiler is written in Bea (src/), and the compiler under test
//// must be able to compile it: as one project, with no error and no
//// warning, every Bea module compiled and every other source passed
//// through.

import bea/project
import bea/system
import gleam/dict
import gleam/list
import gleam/string
import simplifile

/// Files under `dir`, relative to it, sorted.
fn files(dir: String) -> List(String) {
  let assert Ok(paths) = simplifile.get_files(dir)
  paths
  |> list.map(string.drop_start(_, string.length(dir) + 1))
  |> list.sort(string.compare)
}

pub fn compiler_compiles_its_own_source_test() {
  let root = system.absolute_path("build/bea_test_projects/self_hosting")
  let _ = simplifile.delete(root)
  let assert Ok(_) = simplifile.create_directory_all(root)
  let assert Ok(config) = simplifile.read("bea.toml")
  let assert Ok(_) = simplifile.write(root <> "/bea.toml", config)
  let assert Ok(_) = simplifile.copy_directory("src", root <> "/src")
  let assert Ok(p) = project.find(root)
  assert p.name == "bea"
  let sync = project.sync(p, dict.new())
  assert list.map(sync.errors, fn(e) { e.path }) == []
  assert list.map(sync.warnings, fn(w) { w.path }) == []
  // Every `x.bea` became `x.gleam`; FFI files are copied.
  let expected =
    files("src")
    |> list.map(fn(f) {
      case string.ends_with(f, ".bea") {
        True -> string.drop_end(f, 4) <> ".gleam"
        False -> f
      }
    })
    |> list.sort(string.compare)
  assert files(p.build_dir <> "/src") == expected
  assert list.contains(expected, "bea.gleam")
  assert list.contains(expected, "bea/parser.gleam")
  assert list.contains(expected, "bea_ffi.erl")
}
