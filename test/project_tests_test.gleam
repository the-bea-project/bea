//// A project's test/ directory in the generated Gleam project: its Gleam
//// modules and FFI files are mirrored into .beabuild/test/ on every sync,
//// so Gleam compiles them with the project and `bea test` runs them.
//// scripts/test_tooling.sh runs `bea test` itself.

import bea/project
import bea/system
import gleam/dict
import gleam/list
import gleam/string
import simplifile

fn fresh_project(name: String) -> project.Project {
  let root = system.absolute_path("build/bea_test_projects/" <> name)
  let _ = simplifile.delete(root)
  let assert Ok(_) = simplifile.create_directory_all(root <> "/src")
  let assert Ok(_) = simplifile.create_directory_all(root <> "/test/app/data")
  let assert Ok(_) =
    simplifile.write(root <> "/bea.toml", project.default_config(name))
  let assert Ok(_) =
    simplifile.write(
      root <> "/src/" <> name <> ".bea",
      "pub def main() {\n  Nil\n}\n",
    )
  let assert Ok(p) = project.find(root)
  p
}

/// Files under the generated project's test/, relative to it.
fn built_tests(p: project.Project) -> List(String) {
  let dir = p.build_dir <> "/test/"
  case simplifile.get_files(p.build_dir <> "/test") {
    Ok(files) ->
      files
      |> list.map(string.drop_start(_, string.length(dir)))
      |> list.sort(string.compare)
    Error(_) -> []
  }
}

pub fn tests_are_mirrored_test() {
  let p = fresh_project("tests_mirrored")
  let write = fn(path, content) {
    let assert Ok(_) = simplifile.write(p.root <> "/test/" <> path, content)
    Nil
  }
  write("tests_mirrored_test.gleam", "pub fn main() {\n  Nil\n}\n")
  write("app/helper.gleam", "pub fn x() {\n  1\n}\n")
  write("app/helper_ffi.erl", "-module(helper_ffi).\n")
  // Not test modules: fixtures, data and scripts stay where they are.
  write("app/data/fixture.bea", "pub def main() {\n  1\n}\n")
  write("app/data/input.txt", "data")
  write("run.py", "print(1)")
  let sync = project.sync(p, dict.new())
  assert sync.errors == []
  assert built_tests(p)
    == ["app/helper.gleam", "app/helper_ffi.erl", "tests_mirrored_test.gleam"]
  let assert Ok(copy) = simplifile.read(p.build_dir <> "/test/app/helper.gleam")
  assert copy == "pub fn x() {\n  1\n}\n"
  // They are reported as written, the first time only.
  assert list.any(sync.written, string.ends_with(_, "/test/app/helper.gleam"))
  let again = project.sync(p, dict.new())
  assert !list.any(again.written, string.contains(_, "/test/"))
}

pub fn removed_tests_are_removed_test() {
  let p = fresh_project("tests_removed")
  let path = p.root <> "/test/app/old_test.gleam"
  let assert Ok(_) = simplifile.write(path, "pub fn old_test() {\n  Nil\n}\n")
  let _ = project.sync(p, dict.new())
  assert built_tests(p) == ["app/old_test.gleam"]
  let assert Ok(_) = simplifile.delete(path)
  let _ = project.sync(p, dict.new())
  assert built_tests(p) == []
}

pub fn changed_tests_are_updated_test() {
  let p = fresh_project("tests_changed")
  let path = p.root <> "/test/tests_changed_test.gleam"
  let assert Ok(_) = simplifile.write(path, "pub fn main() {\n  1\n}\n")
  let _ = project.sync(p, dict.new())
  let assert Ok(_) = simplifile.write(path, "pub fn main() {\n  2\n}\n")
  let sync = project.sync(p, dict.new())
  assert list.any(sync.written, string.ends_with(
    _,
    "/test/tests_changed_test.gleam",
  ))
  let assert Ok(copy) =
    simplifile.read(p.build_dir <> "/test/tests_changed_test.gleam")
  assert copy == "pub fn main() {\n  2\n}\n"
}

pub fn scripts_have_no_tests_test() {
  // `bea run some/dir/file.bea` outside a project: the file's directory is
  // the source directory, and nothing else of it is copied.
  let root = system.absolute_path("build/bea_test_projects/tests_script")
  let _ = simplifile.delete(root)
  let assert Ok(_) = simplifile.create_directory_all(root <> "/test")
  let assert Ok(_) =
    simplifile.write(
      root <> "/test/x_test.gleam",
      "pub fn main() {\n  Nil\n}\n",
    )
  let assert Ok(_) =
    simplifile.write(root <> "/script.bea", "pub def main() {\n  Nil\n}\n")
  let p = project.script(root <> "/script.bea")
  let _ = project.sync(p, dict.new())
  assert simplifile.is_directory(p.build_dir <> "/test") != Ok(True)
}
