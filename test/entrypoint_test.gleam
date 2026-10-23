import bea/entrypoint.{RunArgs}
import gleam/option.{None, Some}
import gleam/string

fn parse(args: List(String)) -> entrypoint.RunArgs {
  let assert Ok(parsed) = entrypoint.parse_run_args(args)
  parsed
}

fn parse_error(args: List(String)) -> String {
  let assert Error(message) = entrypoint.parse_run_args(args)
  message
}

pub fn no_arguments_runs_the_project_test() {
  assert parse([]) == RunArgs(None, None, None, None, [], [], False)
}

pub fn module_without_arguments_test() {
  let a = parse(["-m", "marmot"])
  assert a.module == Some("marmot")
  assert a.program_args == []
  assert a.build_flags == []
}

// The regression: `--help` after `-m` used to become `gleam build --help`,
// which printed Gleam's help, built nothing and returned 0, after which the
// (unbuilt) program was started anyway.
pub fn help_is_bea_runs_own_help_test() {
  assert parse(["--help"]).help
  assert parse(["-h"]).help
  let a = parse(["-m", "marmot", "--help"])
  assert a.help
  assert a.build_flags == []
}

pub fn first_positional_starts_the_program_arguments_test() {
  assert parse(["-m", "marmot", "help"]).program_args == ["help"]
  let a = parse(["-m", "marmot", "migrate", "--database", "dev.sqlite"])
  assert a.module == Some("marmot")
  assert a.program_args == ["migrate", "--database", "dev.sqlite"]
  assert a.build_flags == []
  // Even `--help` belongs to the program once its arguments have started.
  assert parse(["-m", "marmot", "seed", "--help"]).program_args
    == ["seed", "--help"]
  assert !parse(["-m", "marmot", "seed", "--help"]).help
}

pub fn double_dash_separates_program_arguments_test() {
  let a = parse(["-m", "marmot", "--", "--database", "dev.sqlite"])
  assert a.module == Some("marmot")
  assert a.program_args == ["--database", "dev.sqlite"]
  // Only the first `--` is a separator.
  assert parse(["-m", "t", "--", "a", "--", "b"]).program_args
    == ["a", "--", "b"]
  assert parse(["-m", "t", "a", "--", "b"]).program_args == ["a", "--", "b"]
}

pub fn arguments_are_passed_unchanged_test() {
  assert parse(["-m", "t", "two words", "", "-"]).program_args
    == ["two words", "", "-"]
}

pub fn build_flags_go_to_gleam_build_test() {
  let a =
    parse([
      "--target", "javascript", "--runtime", "bun", "--warnings-as-errors", "-m",
      "app/cli", "x",
    ])
  assert a.target == Some("javascript")
  assert a.runtime == Some("bun")
  assert a.build_flags == ["--target", "javascript", "--warnings-as-errors"]
  assert a.program_args == ["x"]
  let b = parse(["--module=tool", "--target=erlang", "--no-print-progress"])
  assert b.module == Some("tool")
  assert b.build_flags == ["--target", "erlang", "--no-print-progress"]
  assert parse(["-t", "js"]).target == Some("js")
}

pub fn files_test() {
  let a = parse(["scripts/hello.bea", "--", "--verbose"])
  assert a.file == Some("scripts/hello.bea")
  assert a.program_args == ["--verbose"]
  assert parse(["scripts/hello.bea", "world"]).program_args == ["world"]
  // With a module, a `.bea` argument is the program's.
  let b = parse(["-m", "tool", "input.bea"])
  assert b.file == None
  assert b.program_args == ["input.bea"]
  assert parse([".", "-m", "x"]).module == Some("x")
}

pub fn unknown_options_are_errors_test() {
  let message = parse_error(["-m", "marmot", "--database", "dev.sqlite"])
  assert string.contains(message, "`--database`")
  assert string.contains(message, "bea run -m marmot -- --database dev.sqlite")
  assert string.contains(parse_error(["-m"]), "needs the name of the module")
  assert string.contains(parse_error(["--target"]), "erlang or javascript")
  assert string.contains(parse_error(["--runtime"]), "nodejs")
}

pub fn module_names_test() {
  assert entrypoint.check_module_name("marmot") == Ok(Nil)
  assert entrypoint.check_module_name("app/tasks/seed_2") == Ok(Nil)
  let assert Error(_) = entrypoint.check_module_name("Marmot")
  let assert Error(_) = entrypoint.check_module_name("a-b")
  let assert Error(_) = entrypoint.check_module_name("x')")
  let assert Error(_) = entrypoint.check_module_name("")
  let assert Error(_) = entrypoint.check_module_name("a//b")
}

pub fn dependency_names_test() {
  let config =
    "name = \"app\"
version = \"1.0.0\"

[dependencies]
gleam_stdlib = \">= 0.44.0 and < 2.0.0\"
sqlight = { version = \">= 1.2.0 and < 2.0.0\" }

[dev_dependencies]
marmot = \">= 1.9.1 and < 2.0.0\"

[tools.marmot]
database = \"dev.sqlite\"
"
  assert entrypoint.dependency_names(config)
    == ["gleam_stdlib", "sqlight", "marmot"]
}
