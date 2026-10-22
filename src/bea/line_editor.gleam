//// A small line editor for `bea shell`: the terminal is put in raw mode
//// and keys are handled here, so the line can be highlighted as it is
//// typed.
////
//// Keys: ←/→, Home/End (Ctrl+A/E), ↑/↓ for history, Backspace/Delete,
//// Ctrl+W (delete word), Ctrl+U/K (delete to start/end), Ctrl+L (clear
//// screen), Ctrl+C (drop the line), Ctrl+D (quit on an empty line), Tab
//// (two spaces). Raw mode needs OTP 28+; on OTP 27, or when stdin isn't a
//// terminal, lines are read as they come (no live highlighting).

import gleam/int
import gleam/list
import gleam/string

@external(erlang, "bea_ffi", "shell_raw_mode")
fn raw_mode() -> Result(String, Nil)

@external(erlang, "bea_ffi", "shell_restore_mode")
fn restore_mode(saved: String) -> Nil

@external(erlang, "bea_ffi", "shell_read_char")
fn read_char() -> Result(String, Nil)

@external(erlang, "bea_ffi", "shell_write")
fn write(text: String) -> Nil

@external(erlang, "bea_ffi", "shell_read_line")
fn read_plain_line(prompt: String) -> Result(String, Nil)

pub type Line {
  /// The line typed (without the newline).
  Line(String)
  /// Ctrl+C: the line was dropped.
  Cancelled
  /// Ctrl+D on an empty line, or the end of the input.
  Eof
}

type State {
  State(
    /// Graphemes before and after the cursor (`before` reversed).
    before: List(String),
    after: List(String),
    /// History entries above (most recent first) and below the one shown.
    up: List(String),
    down: List(String),
    /// What was being typed before moving into the history.
    draft: String,
  )
}

/// Read a line. `prompt` is printed as is (it may be coloured);
/// `prompt_width` is its width on screen. `paint` colours the text typed.
pub fn read(
  prompt: String,
  prompt_width: Int,
  history: List(String),
  paint: fn(String) -> String,
) -> Line {
  case raw_mode() {
    Error(_) ->
      case read_plain_line(prompt) {
        Ok(line) -> Line(string.trim_end(line))
        Error(_) -> Eof
      }
    Ok(saved) -> {
      let state = State([], [], history, [], "")
      render(prompt, prompt_width, state, paint)
      let line = loop(prompt, prompt_width, state, paint)
      write("\r\n")
      restore_mode(saved)
      line
    }
  }
}

fn text(state: State) -> String {
  string.concat(list.reverse(state.before)) <> string.concat(state.after)
}

fn set_text(state: State, text: String) -> State {
  State(..state, before: list.reverse(string.to_graphemes(text)), after: [])
}

fn render(
  prompt: String,
  prompt_width: Int,
  state: State,
  paint: fn(String) -> String,
) -> Nil {
  let column = prompt_width + list.length(state.before)
  write(
    "\r\u{001b}[K"
    <> prompt
    <> paint(text(state))
    <> "\r"
    <> case column {
      0 -> ""
      n -> "\u{001b}[" <> int.to_string(n) <> "C"
    },
  )
}

fn loop(
  prompt: String,
  width: Int,
  state: State,
  paint: fn(String) -> String,
) -> Line {
  case read_key() {
    Error(_) -> Eof
    Ok(key) -> {
      let continue = fn(state) {
        render(prompt, width, state, paint)
        loop(prompt, width, state, paint)
      }
      case key, state {
        Enter, _ -> Line(text(state))
        CtrlC, _ -> Cancelled
        CtrlD, State(before: [], after: [], ..) -> Eof
        CtrlD, State(after: [_, ..rest], ..) ->
          continue(State(..state, after: rest))
        CtrlD, _ -> loop(prompt, width, state, paint)
        Char(c), _ -> continue(State(..state, before: [c, ..state.before]))
        Backspace, State(before: [_, ..rest], ..) ->
          continue(State(..state, before: rest))
        Delete, State(after: [_, ..rest], ..) ->
          continue(State(..state, after: rest))
        Left, State(before: [c, ..rest], ..) ->
          continue(State(..state, before: rest, after: [c, ..state.after]))
        Right, State(after: [c, ..rest], ..) ->
          continue(State(..state, before: [c, ..state.before], after: rest))
        Home, _ ->
          continue(
            State(
              ..state,
              before: [],
              after: list.append(list.reverse(state.before), state.after),
            ),
          )
        End, _ ->
          continue(
            State(
              ..state,
              before: list.append(list.reverse(state.after), state.before),
              after: [],
            ),
          )
        KillStart, _ -> continue(State(..state, before: []))
        KillEnd, _ -> continue(State(..state, after: []))
        KillWord, _ -> {
          let before =
            state.before
            |> list.drop_while(fn(c) { c == " " })
            |> list.drop_while(fn(c) { c != " " })
          continue(State(..state, before:))
        }
        Up, State(up: [previous, ..older], ..) -> {
          let draft = case state.down {
            [] -> text(state)
            _ -> state.draft
          }
          continue(set_text(
            State(..state, up: older, down: [text(state), ..state.down], draft:),
            previous,
          ))
        }
        Down, State(down: [next, ..newer], ..) -> {
          let shown = case newer {
            [] -> state.draft
            _ -> next
          }
          continue(set_text(
            State(..state, up: [text(state), ..state.up], down: newer),
            shown,
          ))
        }
        Clear, _ -> {
          write("\u{001b}[2J\u{001b}[H")
          continue(state)
        }
        _, _ -> loop(prompt, width, state, paint)
      }
    }
  }
}

// --- Keys --------------------------------------------------------------------------------

type Key {
  Char(String)
  Enter
  Backspace
  Delete
  Left
  Right
  Up
  Down
  Home
  End
  KillStart
  KillEnd
  KillWord
  Clear
  CtrlC
  CtrlD
  Ignored
}

fn read_key() -> Result(Key, Nil) {
  case read_char() {
    Error(_) -> Error(Nil)
    Ok(c) ->
      Ok(case c {
        "\r" | "\n" -> Enter
        "\u{7f}" | "\u{8}" -> Backspace
        "\u{1}" -> Home
        "\u{5}" -> End
        "\u{2}" -> Left
        "\u{6}" -> Right
        "\u{10}" -> Up
        "\u{e}" -> Down
        "\u{15}" -> KillStart
        "\u{b}" -> KillEnd
        "\u{17}" -> KillWord
        "\u{c}" -> Clear
        "\u{3}" -> CtrlC
        "\u{4}" -> CtrlD
        "\t" -> Char("  ")
        "\u{1b}" -> escape()
        _ ->
          case string.to_utf_codepoints(c) {
            [cp] ->
              case string.utf_codepoint_to_int(cp) < 32 {
                True -> Ignored
                False -> Char(c)
              }
            _ -> Char(c)
          }
      })
  }
}

/// `ESC [ A`, `ESC O H`, `ESC [ 3 ~`, `ESC [ 1 ; 5 C`, ...
fn escape() -> Key {
  case read_char() {
    Ok("[") | Ok("O") -> csi("")
    _ -> Ignored
  }
}

fn csi(params: String) -> Key {
  case read_char() {
    Error(_) -> Ignored
    Ok(c) ->
      case c {
        "A" -> Up
        "B" -> Down
        "C" -> Right
        "D" -> Left
        "H" -> Home
        "F" -> End
        "~" ->
          case params {
            "1" | "7" -> Home
            "4" | "8" -> End
            "3" -> Delete
            _ -> Ignored
          }
        _ ->
          case string.contains("0123456789;", c) {
            True -> csi(params <> c)
            False -> Ignored
          }
      }
  }
}
