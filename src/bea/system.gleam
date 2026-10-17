//// Thin wrappers over the Erlang FFI in `bea_ffi.erl`: processes, terminal
//// and environment access.

import gleam/list
import gleam/result
import gleam/string

@external(erlang, "bea_ffi", "init")
pub fn init() -> Nil

@external(erlang, "bea_ffi", "find_executable")
pub fn find_executable(name: String) -> Result(String, Nil)

@external(erlang, "bea_ffi", "get_env")
pub fn get_env(name: String) -> Result(String, Nil)

@external(erlang, "bea_ffi", "cwd")
pub fn cwd() -> String

@external(erlang, "bea_ffi", "absolute_path")
pub fn absolute_path(path: String) -> String

@external(erlang, "bea_ffi", "halt")
pub fn halt(code: Int) -> Nil

@external(erlang, "bea_ffi", "print_stderr")
pub fn print_stderr(text: String) -> Nil

@external(erlang, "bea_ffi", "print")
pub fn print(text: String) -> Nil

@external(erlang, "bea_ffi", "is_tty")
pub fn is_tty() -> Bool

@external(erlang, "bea_ffi", "read_stdin_all")
pub fn read_stdin() -> String

@external(erlang, "bea_ffi", "monotonic_ms")
pub fn monotonic_ms() -> Int

/// Run a program capturing its combined output line by line.
@external(erlang, "bea_ffi", "run_lines")
pub fn run_lines(
  executable: String,
  args: List(String),
  cwd: String,
  state: state,
  on_line: fn(state, String) -> state,
) -> #(Int, state)

/// Run a program attached to the terminal. Returns the exit code.
@external(erlang, "bea_ffi", "run_inherit")
pub fn run_inherit(executable: String, args: List(String), cwd: String) -> Int

/// Run a program attached to the terminal, except that stderr is captured
/// line by line.
@external(erlang, "bea_ffi", "run_stderr_lines")
pub fn run_stderr_lines(
  executable: String,
  args: List(String),
  cwd: String,
  state: state,
  on_line: fn(state, String) -> state,
) -> #(Int, state)

/// The Gleam executable: `$BEA_GLEAM` or `gleam` on the PATH.
pub fn gleam_executable() -> Result(String, String) {
  case get_env("BEA_GLEAM") {
    Ok(path) -> Ok(path)
    Error(_) ->
      find_executable("gleam")
      |> result.replace_error(
        "Bea needs the Gleam compiler, but `gleam` was not found on your PATH.\n"
        <> "Install it from https://gleam.run/getting-started/installing/ "
        <> "or set BEA_GLEAM to its location.",
      )
  }
}

/// Should we print ANSI colours? Respects NO_COLOR and FORCE_COLOR.
pub fn colour() -> Bool {
  case get_env("NO_COLOR"), get_env("FORCE_COLOR") {
    Ok(v), _ if v != "" -> False
    _, Ok(v) if v != "" -> True
    _, _ -> is_tty()
  }
}

pub fn join_path(parts: List(String)) -> String {
  parts
  |> list.filter(fn(p) { p != "" && p != "." })
  |> string.join("/")
  |> string.replace("//", "/")
}
