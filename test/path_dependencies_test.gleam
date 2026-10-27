//// `path` dependencies: `.beabuild/gleam.toml` has them relative to the
//// build directory, a Bea project dependency is synced and used through its
//// generated Gleam project, and `bea.toml` keeps the paths as written.

import bea/project
import bea/system
import gleam/dict
import gleam/list
import gleam/string
import simplifile

/// `<root>/app` depending on `<root>/<name>`, which is `kind`: "bea",
/// "gleam" or nothing.
fn workspace(root_name: String, dependency: String, kind: String) {
  let root = system.absolute_path("build/bea_test_projects/" <> root_name)
  let _ = simplifile.delete(root)
  let app = root <> "/app"
  let dep = root <> "/" <> dependency
  let assert Ok(_) = simplifile.create_directory_all(app <> "/src")
  let assert Ok(_) = simplifile.create_directory_all(dep <> "/src")
  let assert Ok(_) =
    simplifile.write(
      app <> "/bea.toml",
      "name = \"app\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0 and < 2.0.0\"\n"
        <> dependency
        <> " = { path = \"../"
        <> dependency
        <> "\" }\n",
    )
  let assert Ok(_) =
    simplifile.write(
      app <> "/src/app.bea",
      "import "
        <> dependency
        <> "\n\npub def main() {\n  "
        <> dependency
        <> ".hello()\n}\n",
    )
  let config =
    "name = \""
    <> dependency
    <> "\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0 and < 2.0.0\"\n"
  case kind {
    "bea" -> {
      let assert Ok(_) = simplifile.write(dep <> "/bea.toml", config)
      let assert Ok(_) =
        simplifile.write(
          dep <> "/src/" <> dependency <> ".bea",
          "pub def hello() {\n  \"hello\"\n}\n",
        )
      Nil
    }
    _ -> {
      let assert Ok(_) = simplifile.write(dep <> "/gleam.toml", config)
      Nil
    }
  }
  let assert Ok(p) = project.find(app)
  #(p, dep)
}

fn built_config(p: project.Project) -> String {
  let assert Ok(config) = simplifile.read(p.build_dir <> "/gleam.toml")
  config
}

pub fn a_bea_dependency_is_synced_and_used_through_its_build_test() {
  let #(p, dep) = workspace("path_bea", "greeter", "bea")
  let sync = project.sync(p, dict.new())
  assert sync.errors == []
  assert string.contains(
    built_config(p),
    "greeter = { path = \"../../greeter/.beabuild\" }",
  )
  // The dependency's Gleam project exists, with its Bea module compiled.
  let assert Ok(_) = simplifile.read(dep <> "/.beabuild/gleam.toml")
  let assert Ok(module) = simplifile.read(dep <> "/.beabuild/src/greeter.gleam")
  assert string.contains(module, "pub fn hello()")
}

pub fn a_gleam_dependency_is_relative_to_the_build_directory_test() {
  let #(p, dep) = workspace("path_gleam", "glib", "gleam")
  let _ = project.sync(p, dict.new())
  assert string.contains(built_config(p), "glib = { path = \"../../glib\" }")
  // Nothing is generated in a Gleam dependency.
  assert simplifile.is_directory(dep <> "/.beabuild") == Ok(False)
}

pub fn errors_in_a_bea_dependency_are_reported_test() {
  let #(p, dep) = workspace("path_errors", "broken", "bea")
  let assert Ok(_) =
    simplifile.write(dep <> "/src/broken.bea", "pub def hello( {\n")
  let sync = project.sync(p, dict.new())
  assert list.map(sync.errors, fn(e) { e.path }) == [dep <> "/src/broken.bea"]
}

pub fn the_config_keeps_its_paths_test() {
  let config =
    "name = \"app\"

[dependencies]
bea_dep = {path = \"../codecs\" }
gleam_dep = { version = \"1.0.0\", path = \"../glib/\" }
absolute = { path = \"/opt/lib\" }

[dev_dependencies.helper]
path = \"helpers\"

[tools.something]
path = \"../codecs\"
"
  let dependencies = [
    project.PathDependency(
      "../codecs",
      "/w/codecs",
      True,
      "../../codecs/.beabuild",
    ),
    project.PathDependency("../glib/", "/w/glib", False, "../../glib"),
    project.PathDependency("/opt/lib", "/opt/lib", False, "/opt/lib"),
    project.PathDependency("helpers", "/w/app/helpers", False, "../helpers"),
  ]
  let gleam = project.gleam_config(config, dependencies)
  assert gleam == "name = \"app\"

[dependencies]
bea_dep = {path = \"../../codecs/.beabuild\" }
gleam_dep = { version = \"1.0.0\", path = \"../../glib\" }
absolute = { path = \"/opt/lib\" }

[dev_dependencies.helper]
path = \"../helpers\"

[tools.something]
path = \"../codecs\"
"
  // `bea add` & co change gleam.toml; bea.toml gets its own paths back.
  assert project.bea_config(gleam, dependencies) == config
}

pub fn path_dependencies_are_found_in_every_dependency_section_test() {
  let #(p, _) = workspace("path_found", "greeter", "bea")
  let assert [dependency] = project.path_dependencies(p)
  assert dependency.path == "../greeter"
  assert dependency.bea
  assert dependency.built == "../../greeter/.beabuild"
  assert string.ends_with(dependency.absolute, "/path_found/greeter")
}

pub fn normalize_resolves_dots_test() {
  assert project.normalize("/a/b/../c/./d/") == "/a/c/d"
  assert project.normalize("/a/../..") == "/"
}
