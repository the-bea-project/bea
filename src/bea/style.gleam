//// The look of the `bea` command: one purple accent on dark greys (red and
//// yellow are kept for errors and warnings only). `bea/highlight` colours
//// code in the same palette.
////
//// Everything here adds ANSI codes unconditionally; callers decide whether
//// colour is wanted (`system.colour()` honours NO_COLOR / FORCE_COLOR).

// 256-colour palette.
pub const purple = "38;5;141"

pub const deep_purple = "38;5;99"

pub const lavender = "38;5;183"

pub const mauve = "38;5;182"

pub const periwinkle = "38;5;147"

pub const orchid = "38;5;177"

pub const plum = "38;5;97"

pub const grey = "38;5;243"

pub const dark_grey = "38;5;240"

pub fn sgr(codes: String, text: String) -> String {
  case text {
    "" -> ""
    _ -> "\u{001b}[" <> codes <> "m" <> text <> "\u{001b}[0m"
  }
}

/// Command verbs, headings, the Bea name: bold purple.
pub fn accent(text: String) -> String {
  sgr("1;" <> purple, text)
}

/// Purple without the weight: commands in help, values.
pub fn highlight(text: String) -> String {
  sgr(purple, text)
}

/// Secondary text: paths, hints, gutters.
pub fn dim(text: String) -> String {
  sgr(grey, text)
}

pub fn faint(text: String) -> String {
  sgr(dark_grey, text)
}

pub fn bold(text: String) -> String {
  sgr("1", text)
}

pub fn error(text: String) -> String {
  sgr("1;31", text)
}

pub fn warning(text: String) -> String {
  sgr("1;33", text)
}

/// The prompt of `bea shell`.
pub fn prompt(text: String) -> String {
  sgr("1;" <> deep_purple, text)
}
