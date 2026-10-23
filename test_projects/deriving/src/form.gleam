//// A deriver of HTML form readers (`application/x-www-form-urlencoded`),
//// in plain Gleam: `@derive(form)` on `Credentials` defines
//// `credentials_form()`. Nothing here knows about JSON, `Dynamic` or Bea.
////
//// Its conventions: a field is the form value named after its label;
//// required text must not be blank; an empty or missing value is `None` for
//// an `Option`; a checkbox (`Bool`) is checked when present. Every invalid
//// field is reported, not only the first. Forms are flat: a record field
//// inside a form record doesn't type check.

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type FormError {
  Missing(field: String)
  Invalid(field: String, expected: String, found: String)
}

/// Reads a record from a form body.
pub type Form(a) {
  Form(read: fn(Dict(String, String)) -> Result(a, List(FormError)))
}

/// Reads one value: what to make of its text (if it was sent), and a
/// stand-in to carry on with when it's invalid, so later fields are checked
/// too.
pub type Value(a) {
  Value(read: fn(Option(String)) -> Result(a, #(String, String)), zero: a)
}

/// The fields of a record, read into a value of type `r`.
pub opaque type Fields(r) {
  Fields(read: fn(Dict(String, String)) -> #(r, List(FormError)))
}

// --- What `@derive(form)` calls -----------------------------------------------------

pub fn record(_constructor: String, fields: fn() -> Fields(r)) -> Form(r) {
  Form(fn(values) {
    case fields().read(values) {
      #(record, []) -> Ok(record)
      #(_, errors) -> Error(errors)
    }
  })
}

pub fn field(
  label: String,
  of: Value(a),
  _get: fn(r) -> a,
  next: fn(a) -> Fields(r),
) -> Fields(r) {
  Fields(fn(values) {
    case of.read(dict.get(values, label) |> option.from_result) {
      Ok(value) -> next(value).read(values)
      Error(#(expected, found)) -> {
        let error = case found {
          "" -> Missing(label)
          _ -> Invalid(label, expected, found)
        }
        let #(record, errors) = next(of.zero).read(values)
        #(record, [error, ..errors])
      }
    }
  })
}

pub fn done(value: r) -> Fields(r) {
  Fields(fn(_) { #(value, []) })
}

// --- Values -------------------------------------------------------------------------

pub fn string() -> Value(String) {
  text("text", "", Ok)
}

pub fn int() -> Value(Int) {
  text("a whole number", 0, int.parse)
}

pub fn float() -> Value(Float) {
  text("a number", 0.0, fn(s) {
    float.parse(s) |> result.lazy_or(fn() { int.parse(s) |> result.map(int.to_float) })
  })
}

/// A checkbox: checked when sent.
pub fn bool() -> Value(Bool) {
  Value(fn(sent) { Ok(option.is_some(sent)) }, False)
}

pub fn option(of: Value(a)) -> Value(Option(a)) {
  Value(
    fn(sent) {
      case sent |> option.map(string.trim) {
        None | Some("") -> Ok(None)
        Some(_) -> of.read(sent) |> result.map(Some)
      }
    },
    None,
  )
}

fn text(
  expected: String,
  zero: a,
  parse: fn(String) -> Result(a, b),
) -> Value(a) {
  Value(
    fn(sent) {
      let trimmed = option.unwrap(sent, "") |> string.trim
      case trimmed {
        "" -> Error(#(expected, ""))
        _ -> parse(trimmed) |> result.replace_error(#(expected, trimmed))
      }
    },
    zero,
  )
}

// --- Running ------------------------------------------------------------------------

/// Reads a urlencoded body such as `username=admin&password=secret`.
pub fn from_body(body: String, form: Form(a)) -> Result(a, List(FormError)) {
  case uri.parse_query(body) {
    Ok(pairs) -> form.read(dict.from_list(pairs))
    Error(_) -> Error([Invalid("", "a form body", body)])
  }
}
