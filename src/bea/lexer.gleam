import gleam/float
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

  // --- Bool Ops ---
  And
  Or
  Not

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
  LessEq
  Greater
  GreaterEq
  Plus
  Minus
  Star
  Slash
  Percent
  PlusDot
  MinusDot
  StarDot
  SlashDot
  PipeRight
  Caret
  Question
  Pipe
  Colon
  Hash
  Ampersand
  Underscore
  Comma
  Dot
  Arrow
  EqEq
  BangEq
  Concat

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
  FloatLit(Float)
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
    // Whitespace: Ignore and keep scanning
    [" ", ..rest] | ["\n", ..rest] | ["\t", ..rest] | ["\r", ..rest] ->
      scan(rest, tokens)

    // Arrow
    ["-", ">", ..rest] -> scan(rest, [Arrow, ..tokens])

    // Two-character operators
    ["<", ">", ..rest] -> scan(rest, [Concat, ..tokens])
    ["|", ">", ..rest] -> scan(rest, [PipeRight, ..tokens])
    ["!", "=", ..rest] -> scan(rest, [BangEq, ..tokens])
    ["=", "=", ..rest] -> scan(rest, [EqEq, ..tokens])
    [">", "=", ..rest] -> scan(rest, [GreaterEq, ..tokens])
    ["<", "=", ..rest] -> scan(rest, [LessEq, ..tokens])

    ["+", ".", ..rest] -> scan(rest, [PlusDot, ..tokens])
    ["-", ".", ..rest] -> scan(rest, [MinusDot, ..tokens])
    ["*", ".", ..rest] -> scan(rest, [StarDot, ..tokens])
    ["/", ".", ..rest] -> scan(rest, [SlashDot, ..tokens])

    // Comments: intercept // and throw away the rest of the line
    ["/", "/", ..rest] -> consume_comment(rest, tokens)

    // Single-character symbols
    ["(", ..rest] -> scan(rest, [LParen, ..tokens])
    [")", ..rest] -> scan(rest, [RParen, ..tokens])
    ["{", ..rest] -> scan(rest, [LBrace, ..tokens])
    ["}", ..rest] -> scan(rest, [RBrace, ..tokens])
    // Lower precendence single-character symbols
    ["+", ..rest] -> scan(rest, [Plus, ..tokens])
    ["-", ..rest] -> scan(rest, [Minus, ..tokens])
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
    [".", ..rest] -> scan(rest, [Dot, ..tokens])
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
            // PASS `False` HERE (meaning: no dot seen yet)
            True -> consume_number(rest, char, False, tokens)
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
    [] -> list.reverse([Eof, wrapper(acc), ..tokens])

    // Found closing quote
    [char, ..rest] if char == delimiter -> {
      scan(rest, [wrapper(acc), ..tokens])
    }

    ["#", "{", ..rest] if delimiter == "\"" -> {
      // 1. Extract the characters of the expression inside #{ }
      let #(inner_chars, after_brace) = extract_until_brace(rest, 0, [])

      // 2. Recursively lex the inner expression
      let inner_tokens = scan(inner_chars, [])

      // 3. scan() returns the tokens in order ending with Eof. 
      // We reverse them and drop the Eof so we can inject them into our token stream.
      let inner_no_eof = case list.reverse(inner_tokens) {
        [Eof, ..rest_inner] -> rest_inner
        other -> other
      }

      // 4. Stitch it together: `acc` <> `inner_expression` <> `...rest of string`
      let t1 = [wrapper(acc), ..tokens]
      let t2 = [Concat, ..t1]
      let t3 = list.append(inner_no_eof, t2)
      let t4 = [Concat, ..t3]

      // Resume consuming the rest of the string with an empty accumulator
      consume_string(after_brace, delimiter, "", wrapper, t4)
    }

    // Normal character (including a `#` that isn't followed by `{`)
    [char, ..rest] ->
      consume_string(rest, delimiter, acc <> char, wrapper, tokens)
  }
}

// Helper to grab characters until we find the closing `}`
fn extract_until_brace(
  chars: List(String),
  depth: Int,
  acc: List(String),
) -> #(List(String), List(String)) {
  case chars {
    [] -> #(list.reverse(acc), [])
    // Reached EOF safely
    ["{", ..rest] -> extract_until_brace(rest, depth + 1, ["{", ..acc])
    ["}", ..rest] -> {
      case depth == 0 {
        True -> #(list.reverse(acc), rest)
        False -> extract_until_brace(rest, depth - 1, ["}", ..acc])
      }
    }
    [char, ..rest] -> extract_until_brace(rest, depth, [char, ..acc])
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
    "and" -> And
    "or" -> Or
    "not" -> Not
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
  has_dot: Bool,
  tokens: List(Token),
) -> List(Token) {
  case chars {
    [char, ..rest] -> {
      case is_digit(char) {
        // Still a digit, keep consuming
        True -> consume_number(rest, acc <> char, has_dot, tokens)

        // Not a digit. Is it the first dot we've seen?
        False -> {
          case char == "." && !has_dot {
            // It's a dot! Keep consuming, but flip has_dot to True
            True -> consume_number(rest, acc <> char, True, tokens)

            // It's not a dot (or it's a second dot). We are done.
            False -> {
              case has_dot {
                True -> {
                  let assert Ok(val) = float.parse(acc)
                  scan(chars, [FloatLit(val), ..tokens])
                }
                False -> {
                  let assert Ok(val) = int.parse(acc)
                  scan(chars, [IntLit(val), ..tokens])
                }
              }
            }
          }
        }
      }
    }

    // Reached the end of the file
    [] -> {
      case has_dot {
        True -> {
          let assert Ok(val) = float.parse(acc)
          list.reverse([Eof, FloatLit(val), ..tokens])
        }
        False -> {
          let assert Ok(val) = int.parse(acc)
          list.reverse([Eof, IntLit(val), ..tokens])
        }
      }
    }
  }
}

fn is_digit(char: String) -> Bool {
  string.contains("0123456789", char)
}

fn consume_comment(chars: List(String), tokens: List(Token)) -> List(Token) {
  case chars {
    // Reached the end of the file while inside a comment
    [] -> list.reverse([Eof, ..tokens])

    // Found the end of the line! Go back to normal scanning
    ["\n", ..rest] -> scan(rest, tokens)

    // Anything else: throw it away and keep consuming
    [_, ..rest] -> consume_comment(rest, tokens)
  }
}
