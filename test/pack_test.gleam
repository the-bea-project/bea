//// `bea pack`: its arguments, where the executable goes, and how gleepack
//// is run. scripts/test_tooling.sh runs the command itself (with a stand-in
//// gleepack, and with the real one when BEA_TEST_GLEEPACK=1).

import bea/pack.{Dependency, Executable, Help, Options, Pack}
import bea/project
import gleam/option.{None, Some}

fn options(args: List(String)) -> pack.Options {
  let assert Ok(Pack(o)) = pack.parse(args)
  o
}

fn project(config: String) -> project.Project {
  project.Project(
    root: "/work/app",
    src_dir: "/work/app/src",
    build_dir: "/work/app/.beabuild",
    name: "app",
    script: False,
    config: config,
  )
}

const config = "name = \"app\"
version = \"1.0.0\"

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"

[tools.gleepack]
module = \"app/cli\"
output = \"dist/app\" # comment
targets = [\"amd64-linux-otp-29.1.1\"]

[tools.other]
output = \"elsewhere\"
"

pub fn no_arguments_test() {
  assert options([]) == Options(output: None, module: None, targets: [])
}

pub fn options_test() {
  assert options(["--output", "bin/app", "-m", "app/cli"])
    == Options(output: Some("bin/app"), module: Some("app/cli"), targets: [])
  assert options(["--output=bin/app", "--module=app/cli"])
    == Options(output: Some("bin/app"), module: Some("app/cli"), targets: [])
  assert options(["-o", "x"]).output == Some("x")
}

pub fn targets_repeat_in_order_test() {
  assert options(["-t", "a", "--target", "b", "--target=c"]).targets
    == ["a", "b", "c"]
}

pub fn help_test() {
  assert pack.parse(["--help"]) == Ok(Help)
  assert pack.parse(["-o", "x", "-h"]) == Ok(Help)
}

pub fn invalid_arguments_test() {
  assert pack.parse(["--frob"]) == Error("Unknown option `--frob`")
  assert pack.parse(["build"]) == Error("Unknown option `build`")
  assert pack.parse(["--output"]) == Error("`--output` needs a value")
  assert pack.parse(["--module="]) == Error("`--module` needs a value")
}

pub fn setting_reads_tools_gleepack_only_test() {
  assert pack.setting(config, "output") == Some("dist/app")
  assert pack.setting(config, "module") == Some("app/cli")
  assert pack.setting(config, "missing") == None
  assert pack.setting("[tools.other]\noutput = \"x\"\n", "output") == None
  assert pack.setting("output = \"top-level\"\n", "output") == None
}

pub fn output_path_test() {
  let p = project("name = \"app\"\n")
  // Default: build/<package> in the project root.
  assert pack.output_path(p, options([]), "/somewhere") == "/work/app/build/app"
  // --output is relative to where `bea pack` runs.
  assert pack.output_path(p, options(["-o", "bin/x"]), "/work/app/sub")
    == "/work/app/sub/bin/x"
  assert pack.output_path(p, options(["-o", "./x"]), "/cwd") == "/cwd/x"
  assert pack.output_path(p, options(["-o", "/abs/x"]), "/cwd") == "/abs/x"
  // bea.toml's is relative to the project root, and --output wins over it.
  let p = project(config)
  assert pack.output_path(p, options([]), "/cwd") == "/work/app/dist/app"
  assert pack.output_path(p, options(["-o", "y"]), "/cwd") == "/cwd/y"
}

pub fn gleepack_args_test() {
  assert pack.gleepack_args(options([]), "/out/app")
    == ["build", "--output=/out/app"]
  assert pack.gleepack_args(
      options(["-m", "app/cli", "-t", "a", "-t", "b"]),
      "/out/app",
    )
    == [
      "build", "--output=/out/app", "--module=app/cli", "--target=a",
      "--target=b",
    ]
}

pub fn command_test() {
  assert pack.command(Executable("/bin/gleepack"), "/bin/gleam", ["build"])
    == #("/bin/gleepack", ["build"])
  assert pack.command(Dependency, "/bin/gleam", ["build", "--output=/x"])
    == #("/bin/gleam", ["run", "-m", "gleepack", "--", "build", "--output=/x"])
}

pub fn gleepack_dependency_test() {
  assert pack.in_manifest(
    "packages = [\n  { name = \"gleepack\", version = \"1.1.0\", build_tools = [\"gleam\"] },\n]",
  )
  assert !pack.in_manifest("packages = [\n  { name = \"gleam_stdlib\" },\n]")
}
