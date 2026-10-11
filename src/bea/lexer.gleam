import gleam/int
import gleam/list
import gleam/string

// src/bea/lexer.gleam

pub type Token {
  // --- Keywords & Visibility ---
  Import
  As
  Pub
  Def
  Fn
  Type
  Const

  // --- Control Flow ---
  If
  Else
  Cond
  Case
  Return
  Loop
  Break
  Continue

  // --- Debugging & Misc ---
  Echo
  Todo
  Panic

  // Membership
  In

  // --- Operators & Symbols ---
  Bang
  Eq
  Less
  Greater
  Plus
  Minus
  Star
  Slash
  Percent
  PipeRight
  Caret
  Question
  Pipe
  Colon
  Hash
  Ampersand
  Underscore
  Comma

  // --- Delimiters ---
  LBrace
  RBrace
  LBracket
  RBracket
  LParen
  RParen

  // --- Literals & Identifiers ---
  StringLit(String)
  CharLit(String)
  RawStringLit(String)
  IntLit(Int)
  Ident(String)
  // e.g., variable_name, function_name
  TypeIdent(String)

  // e.g., Ok, Error, User (capitalized)
  Eof
}

// An easy way to lex a string in Gleam is to convert it
// into a list of graphemes (characters) and use pattern
// matching to recursively chew through them one by one.
pub fn tokenize(source: String) -> List(Token) {
  // Convert a raw string into a list of individual characters
  let chars = string.to_graphemes(source)

  // Start the recursive scanner with an empty token list
  scan(chars, [])
}

fn scan(chars: List(String), tokens: List(Token)) {
  case chars {
    // Base case: End of file. Prepend Eof and reverse the list.
    [] -> list.reverse([Eof, ..tokens])
    //Whitespace: Ignore and keep scanning
    [" ", ..rest] | ["\n", ..rest] | ["\t", ..rest] | ["\r", ..rest] ->
      scan(rest, tokens)
    // Single-character symbols
    ["+", ..rest] -> scan(rest, [Plus, ..tokens])
    ["-", ..rest] -> scan(rest, [Minus, ..tokens])
    ["(", ..rest] -> scan(rest, [LParen, ..tokens])
    [")", ..rest] -> scan(rest, [RParen, ..tokens])
    ["{", ..rest] -> scan(rest, [LBrace, ..tokens])
    ["}", ..rest] -> scan(rest, [RBrace, ..tokens])

    // Two-character operators
    ["|", ">", ..rest] -> scan(rest, [PipeRight, ..tokens])

    // Lower precendence single-character symbols
    ["!", ..rest] -> scan(rest, [Bang, ..tokens])
    ["=", ..rest] -> scan(rest, [Eq, ..tokens])
    ["<", ..rest] -> scan(rest, [Less, ..tokens])
    [">", ..rest] -> scan(rest, [Greater, ..tokens])
    ["*", ..rest] -> scan(rest, [Star, ..tokens])
    ["/", ..rest] -> scan(rest, [Slash, ..tokens])
    ["%", ..rest] -> scan(rest, [Percent, ..tokens])
    ["^", ..rest] -> scan(rest, [Caret, ..tokens])
    ["?", ..rest] -> scan(rest, [Question, ..tokens])
    ["|", ..rest] -> scan(rest, [Pipe, ..tokens])
    // Must come AFTER PipeRight
    [":", ..rest] -> scan(rest, [Colon, ..tokens])
    ["#", ..rest] -> scan(rest, [Hash, ..tokens])
    ["&", ..rest] -> scan(rest, [Ampersand, ..tokens])
    ["_", ..rest] -> scan(rest, [Underscore, ..tokens])
    [",", ..rest] -> scan(rest, [Comma, ..tokens])
    ["[", ..rest] -> scan(rest, [LBracket, ..tokens])
    ["]", ..rest] -> scan(rest, [RBracket, ..tokens])

    // Strings, Chars, and Raw Strings
    ["\"", ..rest] -> consume_string(rest, "\"", "", StringLit, tokens)
    ["'", ..rest] -> consume_string(rest, "'", "", CharLit, tokens)
    ["`", ..rest] -> consume_string(rest, "`", "", RawStringLit, tokens)
    // Catch-all for Identifiers, Keywords, and Numbers
    [char, ..rest] -> {
      case is_alpha(char) {
        True -> consume_ident(rest, char, tokens)
        False -> {
          case is_digit(char) {
            True -> consume_number(rest, char, tokens)
            False -> {
              // Unrecognized character (skip it for now)
              scan(rest, tokens)
            }
          }
        }
      }
    }
  }
}

// Helper to consume characters until the matching quote is found
fn consume_string(
  chars: List(String),
  delimiter: String,
  acc: String,
  wrapper: fn(String) -> Token,
  tokens: List(Token),
) -> List(Token) {
  case chars {
    // Reached End of File before closing quote (unterminated string)
    [] -> list.reverse([Eof, wrapper(acc), ..tokens])

    // Found a character, check if it is our closing quote
    [char, ..rest] if char == delimiter -> {
      scan(rest, [wrapper(acc), ..tokens])
    }

    // Otherwise, append the character and keep consuming
    [char, ..rest] ->
      consume_string(rest, delimiter, acc <> char, wrapper, tokens)
  }
}

fn consume_ident(
  chars: List(String),
  acc: String,
  tokens: List(Token),
) -> List(Token) {
  case chars {
    // If the next character is alphanumeric, keep building the identifier
    [char, ..rest] -> {
      case is_alphanum(char) {
        True -> consume_ident(rest, acc <> char, tokens)
        False -> scan(chars, [match_keyword(acc), ..tokens])
      }
    }
    // End of file reached while parsing identifier
    [] -> list.reverse([Eof, match_keyword(acc), ..tokens])
  }
}

fn match_keyword(word: String) -> Token {
  case word {
    "import" -> Import
    "as" -> As
    "pub" -> Pub
    "def" -> Def
    "fn" -> Fn
    "type" -> Type
    "const" -> Const
    "if" -> If
    "else" -> Else
    "cond" -> Cond
    "case" -> Case
    "return" -> Return
    "loop" -> Loop
    "break" -> Break
    "continue" -> Continue
    "echo" -> Echo
    "todo" -> Todo
    "panic" -> Panic
    "in" -> In
    _ -> {
      // Check if the first letter is uppercase for TypeIdent
      let first_char = string.slice(word, 0, 1)
      let is_upper = string.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ", first_char)
      case is_upper {
        True -> TypeIdent(word)
        False -> Ident(word)
      }
    }
  }
}

fn is_alpha(char: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_", char)
}

fn is_alphanum(char: String) -> Bool {
  string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789",
    char,
  )
}

fn consume_number(
  chars: List(String),
  acc: String,
  tokens: List(Token),
) -> List(Token) {
  case chars {
    [char, ..rest] -> {
      case is_digit(char) {
        True -> consume_number(rest, acc <> char, tokens)
        False -> {
          // Parse the accumulated string into an Int
          let assert Ok(val) = int.parse(acc)
          // Pass `chars` (not `rest`) to scan so it processes the non-digit character next
          scan(chars, [IntLit(val), ..tokens])
        }
      }
    }
    [] -> {
      let assert Ok(val) = int.parse(acc)
      list.reverse([Eof, IntLit(val), ..tokens])
    }
  }
}

fn is_digit(char: String) -> Bool {
  string.contains("0123456789", char)
}
