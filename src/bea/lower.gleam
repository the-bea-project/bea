//// Lowering: rewrites Bea-only constructs into constructs that map directly
//// onto Gleam. The output is still a `bea/ast` tree, so the code generator
//// stays a straightforward printer.
////
//// Passes, in order, for every function body (and anonymous function body):
////
//// 1. `desugar`: `cond` becomes an `if` chain; `a and b?` / `a or b?`
////    become `if`s so the `?` only runs when the right side is evaluated;
////    anonymous function parameters that are patterns get destructured.
//// 2. `hoist`: every `?` is moved out of its expression into a preceding
////    `use x <- result.try(...)` statement.
//// 3. `returns`: early `return`s are turned into nested `case`s,
////    `bool.guard`s, or continuation closures, so every return ends up in tail
////    position.
////
//// Multi-clause functions are then turned into one function whose body is a
//// `case` over the parameters.
////
//// Internal helper functions are referenced through placeholder variables
//// whose names start with `$` (e.g. `$result.try`); the code generator
//// resolves them to properly imported names.

import bea/ast.{
  type CaseClause, type Clause, type Expr, type Item, type Pattern,
  type Statement,
}
import bea/diagnostic.{type Diagnostic}
import bea/span.{type Span}
import gleam/dict
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const result_try = "$result.try"

pub const bool_guard = "$bool.guard"

pub const bool_lazy_guard = "$bool.lazy_guard"

pub fn module(module: ast.Module) -> #(ast.Module, List(Diagnostic)) {
  let results = list.map(module.items, item)
  let items = list.map(results, fn(r) { r.0 })
  let errors = list.flat_map(results, fn(r) { r.1 })
  let errors = list.append(errors, list.flat_map(items, leftover_returns))
  let errors = list.append(errors, list.flat_map(items, leftover_tries))
  #(ast.Module(..module, items: items), errors)
}

fn item(it: Item) -> #(Item, List(Diagnostic)) {
  case it {
    ast.Function(..) -> function(it)
    ast.Const(..) -> #(ast.Const(..it, value: desugar_expr(it.value)), [])
    _ -> #(it, [])
  }
}

// --- Functions -----------------------------------------------------------------

fn is_external(clause: Clause) -> Bool {
  list.any(clause.attributes, fn(a) { a.name == "external" })
}

fn function(it: Item) -> #(Item, List(Diagnostic)) {
  let assert ast.Function(span, name, name_span, clauses) = it
  let heads = list.filter(clauses, fn(c) { c.body == None && !is_external(c) })
  let bodies = list.filter(clauses, fn(c) { c.body != None })
  let externals = list.filter(clauses, is_external)
  let errors = []

  // All clauses must agree on visibility.
  let errors = case clauses {
    [first, ..rest] ->
      case list.find(rest, fn(c) { c.publicity != first.publicity }) {
        Ok(c) -> [
          diagnostic.error(
            "Inconsistent visibility",
            c.name_span,
            "every clause of `" <> name <> "` must be `pub`, or none of them",
          ),
          ..errors
        ]
        Error(_) -> errors
      }
    [] -> errors
  }

  // Annotations in clauses must agree with each other (and the head).
  let errors =
    list.fold(clauses, #(errors, dict.new(), None), fn(acc, c) {
      let #(errors, seen, seen_return) = acc
      let #(errors, seen) =
        list.index_fold(c.params, #(errors, seen), fn(acc, p, i) {
          let #(errors, seen) = acc
          case p.annotation {
            None -> acc
            Some(t) -> {
              let key = type_key(t)
              case dict.get(seen, i) {
                Ok(previous) if previous != key -> #(
                  [
                    diagnostic.error(
                      "Conflicting annotations",
                      t.span,
                      "an earlier clause of `"
                        <> name
                        <> "` gives this parameter the type "
                        <> previous,
                    ),
                    ..errors
                  ],
                  seen,
                )
                Ok(_) -> acc
                Error(_) -> #(errors, dict.insert(seen, i, key))
              }
            }
          }
        })
      let return_key = option.map(c.return_type, type_key)
      let #(errors, seen_return) = case c.return_type, seen_return {
        Some(t), Some(previous) if Some(previous) != return_key -> #(
          [
            diagnostic.error(
              "Conflicting annotations",
              t.span,
              "an earlier clause of `" <> name <> "` returns " <> previous,
            ),
            ..errors
          ],
          seen_return,
        )
        Some(t), None -> #(errors, Some(type_key(t)))
        _, _ -> #(errors, seen_return)
      }
      #(errors, seen, seen_return)
    })
    |> fn(acc) { acc.0 }

  // Structural checks.
  let errors = case heads {
    [_, second, ..] -> [
      diagnostic.error(
        "Duplicate function head",
        second.span,
        "`" <> name <> "` already has a signature",
      ),
      ..errors
    ]
    [head] ->
      case clauses {
        [first, ..] if first == head -> errors
        _ -> [
          diagnostic.error(
            "Misplaced function head",
            head.span,
            "a body-less signature must come before the clauses",
          ),
          ..errors
        ]
      }
    [] -> errors
  }
  let errors = case externals, clauses {
    [_], [_] -> errors
    [], _ -> errors
    [ext, ..], _ -> [
      diagnostic.error(
        "External function with clauses",
        ext.span,
        "an `@external` function must be a single `def`",
      ),
      ..errors
    ]
  }
  let errors = case bodies, externals {
    [], [] -> [
      diagnostic.error(
        "Function without a body",
        name_span,
        "`" <> name <> "` is declared but never defined",
      )
        |> diagnostic.with_hint(
          "Add a clause with a body, or an `@external(...)` attribute.",
        ),
      ..errors
    ]
    _, _ -> errors
  }
  let arity = case clauses {
    [first, ..] -> list.length(first.params)
    [] -> 0
  }
  let errors =
    list.fold(clauses, errors, fn(errors, c) {
      case list.length(c.params) == arity {
        True -> errors
        False -> [
          diagnostic.error(
            "Clauses with different arities",
            c.span,
            "this clause takes "
              <> int.to_string(list.length(c.params))
              <> " argument(s) but the first takes "
              <> int.to_string(arity),
          ),
          ..errors
        ]
      }
    })

  case errors {
    [_, ..] -> #(it, list.reverse(errors))
    [] -> {
      let merged = merge_clauses(span, name_span, clauses, heads, bodies, arity)
      #(ast.Function(span, name, name_span, [merged]), [])
    }
  }
}

fn merge_clauses(
  span: Span,
  name_span: Span,
  clauses: List(Clause),
  heads: List(Clause),
  bodies: List(Clause),
  arity: Int,
) -> Clause {
  let publicity = case list.any(clauses, fn(c) { c.publicity == ast.Public }) {
    True -> ast.Public
    False -> ast.Private
  }
  let doc = list.flat_map(clauses, fn(c) { c.doc })
  let attributes = list.flat_map(clauses, fn(c) { c.attributes }) |> list.unique
  let return_type =
    list.find_map(clauses, fn(c) { option.to_result(c.return_type, Nil) })
  let return_type = option.from_result(return_type)

  case bodies {
    // External function without a fallback body.
    [] -> {
      let assert [c, ..] = clauses
      ast.Clause(..c, publicity:, doc:, attributes:, return_type:)
    }
    [only] ->
      case list.all(only.params, simple_param) {
        True -> {
          let params =
            list.index_map(only.params, fn(p, i) {
              ast.Param(
                ..p,
                label: first_some(clauses, i, fn(p) { p.label }),
                annotation: first_some(clauses, i, fn(p) { p.annotation }),
              )
            })
          ast.Clause(
            span:,
            name_span:,
            publicity:,
            doc:,
            attributes:,
            return_type:,
            params:,
            guard: None,
            body: case only.guard {
              None -> Some(body(option.unwrap(only.body, [])))
              Some(g) ->
                // A guard on a single clause: fall through to a panic.
                Some([
                  ast.Expression(ast.If(
                    only.span,
                    g,
                    body(option.unwrap(only.body, [])),
                    Some([
                      ast.Expression(ast.Panic(
                        only.span,
                        Some(
                          ast.String(only.span, [
                            ast.Text("No clause matched", only.span),
                          ]),
                        ),
                      )),
                    ]),
                  )),
                ])
            },
          )
        }
        False ->
          to_case(
            span,
            name_span,
            clauses,
            heads,
            bodies,
            arity,
            publicity,
            doc,
            attributes,
            return_type,
          )
      }
    _ ->
      to_case(
        span,
        name_span,
        clauses,
        heads,
        bodies,
        arity,
        publicity,
        doc,
        attributes,
        return_type,
      )
  }
}

fn simple_param(p: ast.Param) -> Bool {
  case p.pattern {
    ast.PVar(..) | ast.PDiscard(..) -> True
    _ -> False
  }
}

fn first_some(
  clauses: List(Clause),
  i: Int,
  f: fn(ast.Param) -> Option(a),
) -> Option(a) {
  list.find_map(clauses, fn(c) {
    case list.drop(c.params, i) {
      [p, ..] -> option.to_result(f(p), Nil)
      [] -> Error(Nil)
    }
  })
  |> option.from_result
}

/// The variable name at a parameter position if *every* clause binds the same
/// plain variable there (so it needn't be matched on).
fn shared_name(bodies: List(Clause), i: Int) -> Option(String) {
  let names =
    list.map(bodies, fn(c) {
      case list.drop(c.params, i) {
        [ast.Param(pattern: ast.PVar(_, n), ..), ..] -> Some(n)
        _ -> None
      }
    })
  case names {
    [Some(n), ..rest] ->
      case list.all(rest, fn(x) { x == Some(n) }) {
        True -> Some(n)
        False -> None
      }
    _ -> None
  }
}

fn to_case(
  span: Span,
  name_span: Span,
  clauses: List(Clause),
  heads: List(Clause),
  bodies: List(Clause),
  arity: Int,
  publicity: ast.Publicity,
  doc: List(String),
  attributes: List(ast.Attribute),
  return_type: Option(ast.Type),
) -> Clause {
  let positions = int_range(arity)
  let shared = list.map(positions, fn(i) { #(i, shared_name(bodies, i)) })
  let matched =
    list.filter(shared, fn(s) { s.1 == None }) |> list.map(fn(s) { s.0 })
  // Gleam's `case` needs at least one subject.
  let matched = case matched {
    [] -> positions
    _ -> matched
  }
  let param_name = fn(i) {
    case list.contains(matched, i), list.key_find(shared, i) {
      False, Ok(Some(n)) -> n
      _, _ -> "arg_" <> int.to_string(i)
    }
  }
  let params =
    list.map(positions, fn(i) {
      ast.Param(
        span: name_span,
        label: first_some(clauses, i, fn(p) { p.label }),
        pattern: ast.PVar(name_span, param_name(i)),
        annotation: first_some(clauses, i, fn(p) { p.annotation }),
      )
    })
  let subjects = list.map(matched, fn(i) { ast.Var(name_span, param_name(i)) })
  let case_clauses =
    list.map(bodies, fn(c) {
      let patterns =
        list.map(matched, fn(i) {
          case list.drop(c.params, i) {
            [p, ..] -> p.pattern
            [] -> ast.PDiscard(c.span, "_")
          }
        })
      let stmts = body(option.unwrap(c.body, []))
      ast.CaseClause(c.span, [patterns], c.guard, ast.Block(c.span, stmts))
    })
  let first = case heads {
    [h, ..] -> h
    [] -> {
      let assert [c, ..] = clauses
      c
    }
  }
  ast.Clause(
    span:,
    doc:,
    attributes:,
    publicity:,
    name_span:,
    params:,
    return_type:,
    guard: None,
    body: Some([ast.Expression(ast.Case(span, subjects, case_clauses))]),
  )
  |> fn(c) { ast.Clause(..c, span: first.span |> span.merge(span)) }
}

/// The full lowering pipeline for a function or anonymous function body.
pub fn body(stmts: List(Statement)) -> List(Statement) {
  stmts
  |> desugar_block
  |> hoist_block(Tail)
  |> returns
}

// --- 1. Desugaring -------------------------------------------------------------

fn desugar_stmts(stmts: List(Statement)) -> List(Statement) {
  desugar_block(stmts)
}

/// Desugars a block. A guard takes the rest of the block with it: it
/// becomes the matching branch of a `case`, whose other branch exits.
fn desugar_block(stmts: List(Statement)) -> List(Statement) {
  case stmts {
    [] -> []
    [ast.Guard(s, pattern, annotation, value, otherwise), ..rest] -> [
      ast.Expression(guard_case(
        s,
        pattern,
        annotation,
        value,
        otherwise,
        desugar_block(rest),
      )),
    ]
    [stmt, ..rest] -> [desugar_stmt(stmt), ..desugar_block(rest)]
  }
}

/// ```text
/// pattern = value else fallback     case value {
/// rest                          =>    pattern -> { rest }
///                                     _ -> { return fallback }
///                                   }
/// ```
///
/// `value?` matches `Ok(pattern)` / `Error(binding)`; a guard without a
/// pattern is a boolean one (`True`). The `return` makes the fallback leave
/// the function from anywhere, like `?` does; the return lowering pass turns
/// it back into a plain value where it is in tail position.
fn guard_case(
  s: Span,
  pattern: Option(Pattern),
  annotation: Option(ast.Type),
  value: Expr,
  otherwise: ast.Otherwise,
  rest: List(Statement),
) -> Expr {
  let os = otherwise.span
  let discard = fn(at) { ast.PDiscard(at, "_") }
  let binding = option.lazy_unwrap(otherwise.binding, fn() { discard(os) })
  let constructor = fn(at, name, args: List(Pattern)) {
    ast.PConstructor(
      at,
      None,
      name,
      list.map(args, fn(a) { ast.PatternArg(a.span, None, Some(a)) }),
      False,
    )
  }
  let #(subject, matched, unmatched) = case value, pattern {
    ast.Try(_, inner), _ -> #(
      inner,
      constructor(s, "Ok", [option.lazy_unwrap(pattern, fn() { discard(s) })]),
      constructor(os, "Error", [binding]),
    )
    _, Some(p) -> #(value, p, binding)
    _, None -> #(
      value,
      constructor(s, "True", []),
      option.lazy_unwrap(otherwise.binding, fn() {
        constructor(os, "False", [])
      }),
    )
  }
  let rest = case annotation, pattern {
    Some(t), Some(ast.PVar(ps, name)) -> [
      ast.Assign(ps, ast.PVar(ps, name), Some(t), ast.Var(ps, name)),
      ..rest
    ]
    _, _ -> rest
  }
  // A guard ending its block: the block's value is the bound variable (or
  // Nil), like an assignment's.
  let rest = case rest {
    [] ->
      case pattern {
        Some(ast.PVar(ps, name)) -> [ast.Expression(ast.Var(ps, name))]
        _ -> [ast.Expression(ast.Constructor(s, None, "Nil"))]
      }
    _ -> rest
  }
  ast.Case(s, [desugar_expr(subject)], [
    ast.CaseClause(s, [[matched]], None, ast.Block(s, rest)),
    ast.CaseClause(
      os,
      [[unmatched]],
      None,
      ast.Block(os, exit(desugar_block(otherwise.body), os)),
    ),
  ])
}

/// Make a fallback leave the function: its last expression is returned.
fn exit(stmts: List(Statement), s: Span) -> List(Statement) {
  case always_returns(stmts) {
    True -> stmts
    False ->
      case list.reverse(stmts) {
        [ast.Expression(e), ..before] ->
          list.reverse([ast.Return(e.span, e), ..before])
        _ ->
          list.append(stmts, [ast.Return(s, ast.Constructor(s, None, "Nil"))])
      }
  }
}

fn desugar_stmt(stmt: Statement) -> Statement {
  case stmt {
    ast.Assign(s, p, t, v) -> ast.Assign(s, p, t, desugar_expr(v))
    ast.Expression(e) -> ast.Expression(desugar_expr(e))
    ast.Return(s, e) -> ast.Return(s, desugar_expr(e))
    ast.Use(s, ps, call) -> ast.Use(s, ps, desugar_expr(call))
    // The message is only evaluated if the assertion fails, so a `?` in it
    // must not be hoisted in front of the assertion.
    ast.Assert(s, e, Some(m)) ->
      case contains_try(m) {
        True ->
          ast.Expression(ast.If(
            s,
            ast.Not(s, desugar_expr(e)),
            [ast.Expression(ast.Panic(s, Some(desugar_expr(m))))],
            None,
          ))
        False -> ast.Assert(s, desugar_expr(e), Some(desugar_expr(m)))
      }
    ast.Assert(s, e, None) -> ast.Assert(s, desugar_expr(e), None)
    ast.Guard(..) -> {
      let assert [lowered] = desugar_block([stmt])
      lowered
    }
  }
}

fn desugar_expr(e: Expr) -> Expr {
  let d = desugar_expr
  case e {
    ast.Int(..)
    | ast.Float(..)
    | ast.RawString(..)
    | ast.Var(..)
    | ast.Constructor(..)
    | ast.Hole(..) -> e
    ast.String(s, parts) ->
      ast.String(
        s,
        list.map(parts, fn(p) {
          case p {
            ast.Interpolation(x, ps) -> ast.Interpolation(d(x), ps)
            _ -> p
          }
        }),
      )
    ast.FieldAccess(s, b, f, fs) -> ast.FieldAccess(s, d(b), f, fs)
    ast.TupleIndex(s, b, i) -> ast.TupleIndex(s, d(b), i)
    ast.Call(s, f, args) -> ast.Call(s, d(f), list.map(args, desugar_arg))
    ast.RecordUpdate(s, c, b, args) ->
      ast.RecordUpdate(s, c, d(b), list.map(args, desugar_arg))
    ast.Tuple(s, es) -> ast.Tuple(s, list.map(es, d))
    ast.List(s, es, t) -> ast.List(s, list.map(es, d), option.map(t, d))
    ast.Map(s, b, pairs) ->
      ast.Map(
        s,
        option.map(b, d),
        list.map(pairs, fn(kv) { #(d(kv.0), d(kv.1)) }),
      )
    ast.Fn(s, params, ret, stmts) -> anonymous_fn(s, params, ret, stmts)
    ast.FnClauses(s, clauses) -> {
      // Create a unique, non-discard variable name
      let arg_name = "bea_param_" <> int.to_string(s.start)
      let arg_var = ast.Var(s, arg_name)
      let param = ast.FnParam(s, ast.PVar(s, arg_name), None)

      // Desugar the inner case clauses recursively so ? and return work
      let d_clauses =
        list.map(clauses, fn(c) {
          ast.CaseClause(
            ..c,
            guard: option.map(c.guard, desugar_expr),
            body: desugar_expr(c.body),
          )
        })

      let body = [ast.Expression(ast.Case(s, [arg_var], d_clauses))]
      ast.Fn(s, [param], None, body)
    }
    ast.Block(s, stmts) -> ast.Block(s, desugar_stmts(stmts))
    ast.If(s, c, t, el) ->
      ast.If(s, d(c), desugar_stmts(t), option.map(el, desugar_stmts))
    ast.Cond(s, clauses) -> cond(s, clauses)
    ast.Case(s, subjects, clauses) ->
      ast.Case(
        s,
        list.map(subjects, d),
        list.map(clauses, fn(c) {
          ast.CaseClause(..c, guard: option.map(c.guard, d), body: d(c.body))
        }),
      )
    ast.BinaryOp(s, ast.And, l, r) ->
      case contains_try(r) {
        True ->
          ast.If(
            s,
            d(l),
            [ast.Expression(d(r))],
            Some([
              ast.Expression(ast.Constructor(s, None, "False")),
            ]),
          )
        False -> ast.BinaryOp(s, ast.And, d(l), d(r))
      }
    ast.BinaryOp(s, ast.Or, l, r) ->
      case contains_try(r) {
        True ->
          ast.If(
            s,
            d(l),
            [ast.Expression(ast.Constructor(s, None, "True"))],
            Some([ast.Expression(d(r))]),
          )
        False -> ast.BinaryOp(s, ast.Or, d(l), d(r))
      }
    ast.BinaryOp(s, op, l, r) -> ast.BinaryOp(s, op, d(l), d(r))
    ast.Negate(s, x) -> ast.Negate(s, d(x))
    ast.NegateFloat(s, x) -> ast.NegateFloat(s, d(x))
    ast.Not(s, x) -> ast.Not(s, d(x))
    ast.Echo(s, x, m) -> ast.Echo(s, option.map(x, d), option.map(m, d))
    ast.Try(s, x) -> ast.Try(s, d(x))
    ast.Panic(s, m) -> ast.Panic(s, option.map(m, d))
    ast.Todo(s, m) -> ast.Todo(s, option.map(m, d))
    ast.BitArray(s, segs) ->
      ast.BitArray(
        s,
        list.map(segs, fn(seg) {
          ast.Segment(
            ..seg,
            value: d(seg.value),
            options: list.map(seg.options, fn(o) {
              ast.SegmentOption(..o, arg: option.map(o.arg, d))
            }),
          )
        }),
      )
  }
}

fn desugar_arg(a: ast.Arg) -> ast.Arg {
  ast.Arg(..a, value: option.map(a.value, desugar_expr))
}

fn cond(s: Span, clauses: List(ast.CondClause)) -> Expr {
  case clauses {
    [] ->
      ast.Panic(s, Some(ast.String(s, [ast.Text("No cond clause matched", s)])))
    [ast.CondClause(_, ast.Constructor(_, None, "True"), body), ..]
    | [ast.CondClause(_, ast.Hole(_), body), ..] -> desugar_expr(body)
    [ast.CondClause(cs, c, body), ..rest] ->
      ast.If(
        cs,
        desugar_expr(c),
        [ast.Expression(desugar_expr(body))],
        Some([ast.Expression(cond(s, rest))]),
      )
  }
}

fn anonymous_fn(
  s: Span,
  params: List(ast.FnParam),
  ret: Option(ast.Type),
  stmts: List(Statement),
) -> Expr {
  // Gleam anonymous functions only take names; destructure patterns inside.
  let #(params, binds) =
    list.map(params, fn(p) {
      case p.pattern {
        ast.PVar(..) | ast.PDiscard(..) -> #(p, [])
        pat -> {
          let name = "bea_param_" <> int.to_string(p.span.start)
          #(
            ast.FnParam(
              ..p,
              pattern: ast.PVar(p.span, name),
              annotation: p.annotation,
            ),
            [
              ast.Assign(p.span, pat, None, ast.Var(p.span, name)),
            ],
          )
        }
      }
    })
    |> list.unzip
  ast.Fn(s, params, ret, body(list.append(list.flatten(binds), stmts)))
}

fn contains_try(e: Expr) -> Bool {
  case e {
    ast.Try(..) -> True
    ast.Fn(..) -> False
    _ -> list.any(children(e), contains_try)
  }
}

/// Direct sub-expressions, excluding statement bodies.
fn children(e: Expr) -> List(Expr) {
  case e {
    ast.Int(..)
    | ast.Float(..)
    | ast.RawString(..)
    | ast.Var(..)
    | ast.Constructor(..)
    | ast.Hole(..) -> []
    ast.String(_, parts) ->
      list.filter_map(parts, fn(p) {
        case p {
          ast.Interpolation(x, _) -> Ok(x)
          _ -> Error(Nil)
        }
      })
    ast.FieldAccess(base:, ..) | ast.TupleIndex(base:, ..) -> [base]
    ast.Call(_, f, args) -> [f, ..arg_values(args)]
    ast.RecordUpdate(_, c, b, args) -> [c, b, ..arg_values(args)]
    ast.Tuple(_, es) -> es
    ast.List(_, es, t) -> list.append(es, opt_list(t))
    ast.Map(_, b, pairs) ->
      list.append(opt_list(b), list.flat_map(pairs, fn(kv) { [kv.0, kv.1] }))
    ast.Fn(..) | ast.FnClauses(..) -> []
    ast.Block(_, stmts) -> list.flat_map(stmts, statement_exprs)
    ast.If(_, c, t, el) -> [
      c,
      ..list.flat_map(list.append(t, option.unwrap(el, [])), statement_exprs)
    ]
    ast.Cond(_, clauses) ->
      list.flat_map(clauses, fn(c) { [c.condition, c.body] })
    ast.Case(_, subjects, clauses) ->
      list.append(
        subjects,
        list.flat_map(clauses, fn(c) {
          list.append(opt_list(c.guard), [c.body])
        }),
      )
    ast.BinaryOp(_, _, l, r) -> [l, r]
    ast.Negate(_, x) | ast.NegateFloat(_, x) | ast.Not(_, x) | ast.Try(_, x) -> [
      x,
    ]
    ast.Echo(_, x, m) -> list.append(opt_list(x), opt_list(m))
    ast.Panic(_, m) | ast.Todo(_, m) -> opt_list(m)
    ast.BitArray(_, segs) ->
      list.flat_map(segs, fn(s) {
        [
          s.value,
          ..list.filter_map(s.options, fn(o) { option.to_result(o.arg, Nil) })
        ]
      })
  }
}

fn arg_values(args: List(ast.Arg)) -> List(Expr) {
  list.filter_map(args, fn(a) { option.to_result(a.value, Nil) })
}

fn statement_exprs(stmt: Statement) -> List(Expr) {
  case stmt {
    ast.Assign(value:, ..) -> [value]
    ast.Expression(e) -> [e]
    ast.Return(value:, ..) -> [value]
    ast.Use(call:, ..) -> [call]
    ast.Assert(value:, message:, ..) -> [value, ..opt_list(message)]
    ast.Guard(value:, otherwise:, ..) -> [
      value,
      ..list.flat_map(otherwise.body, statement_exprs)
    ]
  }
}

// --- 2. `?` hoisting -----------------------------------------------------------

fn try_call(s: Span, value: Expr) -> Expr {
  ast.Call(s, ast.Var(s, result_try), [ast.Arg(value.span, None, Some(value))])
}

fn try_name(s: Span) -> String {
  "bea_try_" <> int.to_string(s.start)
}

/// Is the statement list being processed in tail position, i.e. is its value
/// the value of the enclosing function? Only then can `?` use Gleam's
/// `use x <- result.try(...)`, which short-circuits the *rest of the block*.
/// Elsewhere `?` becomes an early `return Error(e)`, which the return
/// lowering pass then propagates out of the enclosing branches.
type Tail {
  Tail
  NotTail
}

/// `pattern = value?` (or `value?` alone when `pattern` is None).
fn bind_try(
  tail: Tail,
  s: Span,
  pattern: Option(#(Pattern, Option(ast.Type))),
  value: Expr,
) -> List(Statement) {
  case tail {
    Tail ->
      case pattern {
        Some(#(ast.PVar(..) as p, annotation))
        | Some(#(ast.PDiscard(..) as p, annotation)) -> [
          ast.Use(
            s,
            [ast.UsePattern(p.span, p, annotation)],
            try_call(s, value),
          ),
        ]
        Some(#(p, annotation)) -> {
          let name = try_name(s)
          [
            ast.Use(
              s,
              [ast.UsePattern(s, ast.PVar(s, name), None)],
              try_call(s, value),
            ),
            ast.Assign(s, p, annotation, ast.Var(s, name)),
          ]
        }
        None -> [
          ast.Use(
            s,
            [ast.UsePattern(s, ast.PDiscard(s, "_"), None)],
            try_call(s, value),
          ),
        ]
      }
    NotTail -> {
      let n = int.to_string(s.start)
      let ok = "bea_ok_" <> n
      let err = "bea_error_" <> n
      let unwrap =
        ast.Case(s, [value], [
          ast.CaseClause(
            s,
            [
              [
                ast.PConstructor(
                  s,
                  None,
                  "Ok",
                  [ast.PatternArg(s, None, Some(ast.PVar(s, ok)))],
                  False,
                ),
              ],
            ],
            None,
            ast.Var(s, ok),
          ),
          ast.CaseClause(
            s,
            [
              [
                ast.PConstructor(
                  s,
                  None,
                  "Error",
                  [ast.PatternArg(s, None, Some(ast.PVar(s, err)))],
                  False,
                ),
              ],
            ],
            None,
            ast.Block(s, [
              ast.Return(
                s,
                ast.Call(s, ast.Constructor(s, None, "Error"), [
                  ast.Arg(s, None, Some(ast.Var(s, err))),
                ]),
              ),
            ]),
          ),
        ])
      case pattern {
        Some(#(p, annotation)) -> [ast.Assign(s, p, annotation, unwrap)]
        None -> [ast.Assign(s, ast.PDiscard(s, "_"), None, unwrap)]
      }
    }
  }
}

fn hoist_block(stmts: List(Statement), tail: Tail) -> List(Statement) {
  case stmts {
    [] -> []
    [last] -> hoist_stmt(last, True, tail)
    [stmt, ..rest] ->
      list.append(hoist_stmt(stmt, False, tail), hoist_block(rest, tail))
  }
}

fn hoist_stmt(stmt: Statement, is_last: Bool, tail: Tail) -> List(Statement) {
  // Branches of the last expression of a tail block are themselves in tail
  // position; so are those of a returned expression.
  let expr_tail = case is_last {
    True -> tail
    False -> NotTail
  }
  case stmt {
    ast.Assign(s, pat, annotation, ast.Try(ts, inner)) -> {
      let #(pre, inner) = hoist(inner, tail, NotTail)
      let _ = s
      list.append(pre, bind_try(tail, ts, Some(#(pat, annotation)), inner))
    }
    ast.Assign(s, pat, annotation, value) -> {
      let #(pre, value) = hoist(value, tail, NotTail)
      list.append(pre, [ast.Assign(s, pat, annotation, value)])
    }
    ast.Expression(ast.Try(ts, inner)) -> {
      let #(pre, inner) = hoist(inner, tail, NotTail)
      case is_last {
        False -> list.append(pre, bind_try(tail, ts, None, inner))
        True -> {
          let name = try_name(ts)
          list.flatten([
            pre,
            bind_try(tail, ts, Some(#(ast.PVar(ts, name), None)), inner),
            [ast.Expression(ast.Var(ts, name))],
          ])
        }
      }
    }
    ast.Expression(e) -> {
      let #(pre, e) = hoist(e, tail, expr_tail)
      list.append(pre, [ast.Expression(e)])
    }
    ast.Return(s, e) -> {
      let #(pre, e) = hoist(e, tail, Tail)
      list.append(pre, [ast.Return(s, e)])
    }
    ast.Use(s, ps, call) -> {
      let #(pre, call) = hoist(call, tail, NotTail)
      list.append(pre, [ast.Use(s, ps, call)])
    }
    ast.Assert(s, e, m) -> {
      let #(pre, e) = hoist(e, tail, NotTail)
      let #(pre2, m) = hoist_option(m, tail)
      list.flatten([pre, pre2, [ast.Assert(s, e, m)]])
    }
    // Guards are desugared before hoisting.
    ast.Guard(..) -> [stmt]
  }
}

/// Moves every `?` inside `e` that is evaluated unconditionally into
/// statements placed before the current statement (in a block whose tailness
/// is `block`). Branching constructs hoist inside their own branches;
/// `expr_tail` says whether those branches are in tail position.
///
/// Evaluation order is preserved: when a sub-expression needs statements
/// hoisted before it, any side-effecting sub-expressions to its left are
/// first bound to temporaries, so they still run first.
fn hoist(e: Expr, block: Tail, expr_tail: Tail) -> #(List(Statement), Expr) {
  case e {
    ast.Try(s, inner) -> {
      let #(pre, inner) = hoist_child(inner, block)
      let name = try_name(s)
      #(
        list.append(
          pre,
          bind_try(block, s, Some(#(ast.PVar(s, name), None)), inner),
        ),
        ast.Var(s, name),
      )
    }
    ast.Int(..)
    | ast.Float(..)
    | ast.RawString(..)
    | ast.Var(..)
    | ast.Constructor(..)
    | ast.Hole(..)
    | ast.Fn(..)
    | ast.Cond(..)
    | ast.FnClauses(..) -> #([], e)
    ast.String(s, parts) -> {
      let exprs =
        list.filter_map(parts, fn(p) {
          case p {
            ast.Interpolation(x, _) -> Ok(x)
            _ -> Error(Nil)
          }
        })
      let #(pre, exprs) = hoist_children(exprs, block)
      let #(_, parts) =
        list.map_fold(parts, exprs, fn(remaining, p) {
          case p, remaining {
            ast.Interpolation(_, ps), [x, ..rest] -> #(
              rest,
              ast.Interpolation(x, ps),
            )
            _, _ -> #(remaining, p)
          }
        })
      #(pre, ast.String(s, parts))
    }
    ast.FieldAccess(s, b, f, fs) -> {
      let #(pre, b) = hoist_child(b, block)
      #(pre, ast.FieldAccess(s, b, f, fs))
    }
    ast.TupleIndex(s, b, i) -> {
      let #(pre, b) = hoist_child(b, block)
      #(pre, ast.TupleIndex(s, b, i))
    }
    ast.Call(s, f, args) -> {
      let #(pre, values) = hoist_children([f, ..arg_values(args)], block)
      let assert [f, ..values] = values
      #(pre, ast.Call(s, f, replace_args(args, values)))
    }
    ast.RecordUpdate(s, c, b, args) -> {
      let #(pre, values) = hoist_children([b, ..arg_values(args)], block)
      let assert [b, ..values] = values
      #(pre, ast.RecordUpdate(s, c, b, replace_args(args, values)))
    }
    ast.Tuple(s, es) -> {
      let #(pre, es) = hoist_children(es, block)
      #(pre, ast.Tuple(s, es))
    }
    ast.List(s, es, t) -> {
      let #(pre, all) = hoist_children(list.append(es, opt_list(t)), block)
      let #(es, t) = case t {
        Some(_) -> {
          let assert [t, ..rev] = list.reverse(all)
          #(list.reverse(rev), Some(t))
        }
        None -> #(all, None)
      }
      #(pre, ast.List(s, es, t))
    }
    ast.Map(s, b, pairs) -> {
      let flat =
        list.append(opt_list(b), list.flat_map(pairs, fn(kv) { [kv.0, kv.1] }))
      let #(pre, flat) = hoist_children(flat, block)
      let #(b, flat) = case b, flat {
        Some(_), [b, ..rest] -> #(Some(b), rest)
        _, _ -> #(None, flat)
      }
      #(pre, ast.Map(s, b, pair_up(flat)))
    }
    ast.Block(s, stmts) -> #([], ast.Block(s, hoist_block(stmts, expr_tail)))
    ast.If(s, c, t, el) -> {
      let #(pre, c) = hoist_child(c, block)
      #(
        pre,
        ast.If(
          s,
          c,
          hoist_block(t, expr_tail),
          option.map(el, hoist_block(_, expr_tail)),
        ),
      )
    }
    ast.Case(s, subjects, clauses) -> {
      let #(pre, subjects) = hoist_children(subjects, block)
      let clauses =
        list.map(clauses, fn(c) {
          let body = case c.body {
            ast.Block(bs, stmts) -> ast.Block(bs, hoist_block(stmts, expr_tail))
            body ->
              case contains_try(body) {
                False -> body
                True ->
                  ast.Block(
                    body.span,
                    hoist_block([ast.Expression(body)], expr_tail),
                  )
              }
          }
          ast.CaseClause(..c, body:)
        })
      #(pre, ast.Case(s, subjects, clauses))
    }
    ast.BinaryOp(s, op, l, r) -> {
      let #(pre, values) = hoist_children([l, r], block)
      let assert [l, r] = values
      #(pre, ast.BinaryOp(s, op, l, r))
    }
    ast.Negate(s, x) -> {
      let #(pre, x) = hoist_child(x, block)
      #(pre, ast.Negate(s, x))
    }
    ast.NegateFloat(s, x) -> {
      let #(pre, x) = hoist_child(x, block)
      #(pre, ast.NegateFloat(s, x))
    }
    ast.Not(s, x) -> {
      let #(pre, x) = hoist_child(x, block)
      #(pre, ast.Not(s, x))
    }
    ast.Echo(s, x, m) -> {
      let #(pre, values) = hoist_children(opt_list(x), block)
      let x = list.first(values) |> option.from_result
      let #(pre2, m) = hoist_option(m, block)
      #(list.append(pre, pre2), ast.Echo(s, x, m))
    }
    ast.Panic(s, m) -> {
      let #(pre, m) = hoist_option(m, block)
      #(pre, ast.Panic(s, m))
    }
    ast.Todo(s, m) -> {
      let #(pre, m) = hoist_option(m, block)
      #(pre, ast.Todo(s, m))
    }
    ast.BitArray(s, segs) -> {
      let #(pre, values) =
        hoist_children(list.map(segs, fn(x) { x.value }), block)
      let segs =
        list.map2(segs, values, fn(seg, v) { ast.Segment(..seg, value: v) })
      #(pre, ast.BitArray(s, segs))
    }
  }
}

/// Hoist a sub-expression. Branching expressions (`if`, `case`, blocks)
/// that contain `?` or `return` are bound to a temporary first, so their
/// early exits happen at statement level where they can be lowered.
fn hoist_child(x: Expr, block: Tail) -> #(List(Statement), Expr) {
  case x {
    ast.If(..) | ast.Case(..) | ast.Block(..) ->
      case contains_try(x) || expr_has_return(x) {
        True -> {
          let #(pre, x2) = hoist(x, block, NotTail)
          let name = "bea_val_" <> int.to_string(x.span.start)
          #(
            list.append(pre, [
              ast.Assign(x.span, ast.PVar(x.span, name), None, x2),
            ]),
            ast.Var(x.span, name),
          )
        }
        False -> hoist(x, block, NotTail)
      }
    _ -> hoist(x, block, NotTail)
  }
}

/// Hoist sibling sub-expressions evaluated left to right.
fn hoist_children(
  es: List(Expr),
  block: Tail,
) -> #(List(Statement), List(Expr)) {
  let parts = list.map(es, hoist_child(_, block))
  // For each element: does any element to its right hoist statements?
  let #(_, later) =
    list.fold_right(parts, #(False, []), fn(acc, part) {
      let #(seen, flags) = acc
      #(seen || part.0 != [], [seen, ..flags])
    })
  list.map2(parts, later, fn(part, later_has_pre) {
    let #(pre, e) = part
    case later_has_pre && !pure(e) {
      True -> {
        let name = "bea_val_" <> int.to_string(e.span.start)
        #(
          list.append(pre, [ast.Assign(e.span, ast.PVar(e.span, name), None, e)]),
          ast.Var(e.span, name),
        )
      }
      False -> #(pre, e)
    }
  })
  |> unzip_flat
}

/// Expressions that can be moved without changing behaviour.
fn pure(e: Expr) -> Bool {
  case e {
    ast.Int(..)
    | ast.Float(..)
    | ast.RawString(..)
    | ast.Var(..)
    | ast.Constructor(..)
    | ast.Hole(..)
    | ast.Fn(..)
    | ast.FnClauses(..) -> True
    ast.String(_, parts) ->
      list.all(parts, fn(p) {
        case p {
          ast.Text(..) -> True
          ast.Interpolation(x, _) -> pure(x)
        }
      })
    ast.FieldAccess(base:, ..) | ast.TupleIndex(base:, ..) -> pure(base)
    ast.Tuple(_, es) -> list.all(es, pure)
    ast.List(_, es, t) -> list.all(list.append(es, opt_list(t)), pure)
    ast.BinaryOp(_, op, l, r) -> op != ast.Pipe && pure(l) && pure(r)
    ast.Negate(_, x) | ast.Not(_, x) -> pure(x)
    _ -> False
  }
}

fn replace_args(args: List(ast.Arg), values: List(Expr)) -> List(ast.Arg) {
  let #(_, args) =
    list.map_fold(args, values, fn(values, a) {
      case a.value, values {
        Some(_), [v, ..rest] -> #(rest, ast.Arg(..a, value: Some(v)))
        _, _ -> #(values, a)
      }
    })
  args
}

fn pair_up(xs: List(a)) -> List(#(a, a)) {
  case xs {
    [k, v, ..rest] -> [#(k, v), ..pair_up(rest)]
    _ -> []
  }
}

fn hoist_option(
  e: Option(Expr),
  block: Tail,
) -> #(List(Statement), Option(Expr)) {
  case e {
    Some(e) -> {
      let #(pre, e) = hoist_child(e, block)
      #(pre, Some(e))
    }
    None -> #([], None)
  }
}

fn unzip_flat(pairs: List(#(List(a), b))) -> #(List(a), List(b)) {
  let #(pres, xs) = list.unzip(pairs)
  #(list.flatten(pres), xs)
}

// --- 3. Early returns ----------------------------------------------------------

fn returns(stmts: List(Statement)) -> List(Statement) {
  case stmts {
    [] -> []
    [ast.Return(_, e), ..] -> [ast.Expression(e)]
    [stmt] ->
      case has_return(stmt) {
        True -> branch(stmt, [])
        False -> [stmt]
      }
    [stmt, ..rest] ->
      case has_return(stmt) {
        False -> [stmt, ..returns(rest)]
        True ->
          case stmt {
            // Guard clause: `if cond { ...; return x }` followed by more code.
            ast.Expression(ast.If(s, c, then, None)) ->
              case always_returns(then) {
                True -> [guard(s, c, then), ..returns(rest)]
                False -> branch(stmt, rest)
              }
            _ -> branch(stmt, rest)
          }
      }
  }
}

fn guard(s: Span, condition: Expr, then: List(Statement)) -> Statement {
  let #(helper, value) = case then {
    [ast.Return(_, e)] ->
      case is_simple(e) {
        True -> #(bool_guard, e)
        False -> #(bool_lazy_guard, ast.Fn(s, [], None, returns(then)))
      }
    _ -> #(bool_lazy_guard, ast.Fn(s, [], None, returns(then)))
  }
  ast.Use(
    s,
    [],
    ast.Call(s, ast.Var(s, helper), [
      ast.Arg(condition.span, Some("when"), Some(condition)),
      ast.Arg(value.span, Some("return"), Some(value)),
    ]),
  )
}

/// Cheap, side effect free expressions can be evaluated eagerly by
/// `bool.guard`; anything else goes through `bool.lazy_guard`.
fn is_simple(e: Expr) -> Bool {
  case e {
    ast.Int(..)
    | ast.Float(..)
    | ast.RawString(..)
    | ast.Var(..)
    | ast.Constructor(..) -> True
    ast.String(_, parts) ->
      list.all(parts, fn(p) {
        case p {
          ast.Text(..) -> True
          ast.Interpolation(x, _) -> is_simple(x)
        }
      })
    ast.Tuple(_, es) -> list.all(es, is_simple)
    ast.List(_, es, None) -> list.all(es, is_simple)
    ast.Call(_, ast.Constructor(..), args) ->
      list.all(arg_values(args), is_simple)
    ast.FieldAccess(_, ast.Var(..), _, _) | ast.TupleIndex(_, ast.Var(..), _) ->
      True
    // Operators can't fail or have side effects (division by zero is 0).
    ast.BinaryOp(_, op, l, r) if op != ast.Pipe -> is_simple(l) && is_simple(r)
    ast.Negate(_, x) | ast.NegateFloat(_, x) | ast.Not(_, x) -> is_simple(x)
    _ -> False
  }
}

type Branch {
  /// Statements of the branch, and whether the branch introduces bindings
  /// that would wrongly be visible to the code after it if inlined.
  Branch(stmts: List(Statement), binds: Bool)
}

/// Lowers a statement containing `return`s that is followed by `rest`.
fn branch(stmt: Statement, rest: List(Statement)) -> List(Statement) {
  let #(expr, binding) = case stmt {
    ast.Expression(e) -> #(e, None)
    ast.Assign(s, p, t, v) -> #(v, Some(#(s, p, t)))
    // Anything else (`use`, `assert`) is reported by `leftover_returns`.
    _ -> #(ast.Hole(span.empty), None)
  }
  case branches_of(expr, option.is_some(binding)) {
    Error(_) -> [stmt, ..returns(rest)]
    Ok(branches) -> {
      let falling = list.filter(branches, fn(b) { !always_returns(b.stmts) })
      let needs_closure = case rest, falling {
        [], _ -> False
        _, [] -> False
        _, [single] -> single.binds
        _, _ -> True
      }
      let k = "bea_continue_" <> int.to_string(ast.statement_span(stmt).start)
      let ks = ast.statement_span(stmt)
      let continue = fn(b: Branch) -> List(Statement) {
        case always_returns(b.stmts) {
          True -> returns(b.stmts)
          False ->
            case needs_closure, binding {
              False, None -> returns(list.append(b.stmts, rest))
              False, Some(#(s, p, t)) ->
                returns(list.append(
                  bind_last(b.stmts, fn(e) { [ast.Assign(s, p, t, e)] }),
                  rest,
                ))
              True, None ->
                returns(
                  list.append(b.stmts, [
                    ast.Expression(ast.Call(ks, ast.Var(ks, k), [])),
                  ]),
                )
              True, Some(_) ->
                returns(
                  bind_last(b.stmts, fn(e) {
                    case expr_has_return(e) {
                      // `k(if c { return 1 } else { 2 })` can't be lowered;
                      // bind the value first and let `returns` handle it.
                      True -> {
                        let v = "bea_value_" <> int.to_string(e.span.start)
                        [
                          ast.Assign(e.span, ast.PVar(e.span, v), None, e),
                          ast.Expression(
                            ast.Call(ks, ast.Var(ks, k), [
                              ast.Arg(e.span, None, Some(ast.Var(e.span, v))),
                            ]),
                          ),
                        ]
                      }
                      False -> [
                        ast.Expression(
                          ast.Call(ks, ast.Var(ks, k), [
                            ast.Arg(e.span, None, Some(e)),
                          ]),
                        ),
                      ]
                    }
                  }),
                )
            }
        }
      }
      let rebuilt = rebuild(expr, list.map(branches, continue))
      case needs_closure {
        False -> [ast.Expression(rebuilt)]
        True -> {
          let closure = case binding {
            None -> ast.Fn(ks, [], None, returns(rest))
            Some(#(s, p, t)) -> {
              let v = "bea_value_" <> int.to_string(ks.start)
              ast.Fn(
                ks,
                [ast.FnParam(ks, ast.PVar(ks, v), t)],
                None,
                returns([ast.Assign(s, p, None, ast.Var(ks, v)), ..rest]),
              )
            }
          }
          [
            ast.Assign(ks, ast.PVar(ks, k), None, closure),
            ast.Expression(rebuilt),
          ]
        }
      }
    }
  }
}

/// Replace the final expression of a branch, used when an assignment's value
/// is a branching expression: `x = if c { return 1 } else { 2 }`.
fn bind_last(
  stmts: List(Statement),
  f: fn(Expr) -> List(Statement),
) -> List(Statement) {
  case list.reverse(stmts) {
    [ast.Expression(e), ..before] -> list.append(list.reverse(before), f(e))
    [] -> f(ast.Constructor(span.empty, None, "Nil"))
    _ -> list.append(stmts, f(ast.Constructor(span.empty, None, "Nil")))
  }
}

fn branches_of(e: Expr, has_binding: Bool) -> Result(List(Branch), Nil) {
  case e {
    ast.If(_, _, then, el) -> {
      // A missing `else` evaluates to Nil; only spell that out when the value
      // is actually used.
      let missing = case has_binding {
        True -> [ast.Expression(ast.Constructor(e.span, None, "Nil"))]
        False -> []
      }
      Ok([
        Branch(then, binds_any(then)),
        Branch(option.unwrap(el, missing), binds_any(option.unwrap(el, []))),
      ])
    }
    ast.Case(_, _, clauses) ->
      Ok(
        list.map(clauses, fn(c) {
          let stmts = clause_stmts(c)
          let pattern_binds =
            list.any(c.alternatives, fn(alt) { list.any(alt, pattern_binds) })
          Branch(stmts, pattern_binds || binds_any(stmts))
        }),
      )
    ast.Block(_, stmts) -> Ok([Branch(stmts, binds_any(stmts))])
    _ -> Error(Nil)
  }
}

fn clause_stmts(c: CaseClause) -> List(Statement) {
  case c.body {
    ast.Block(_, stmts) -> stmts
    body -> [ast.Expression(body)]
  }
}

fn rebuild(e: Expr, branches: List(List(Statement))) -> Expr {
  case e, branches {
    ast.If(s, c, _, _), [t, el] -> ast.If(s, c, t, Some(el))
    ast.Case(s, subjects, clauses), _ ->
      ast.Case(
        s,
        subjects,
        list.map2(clauses, branches, fn(c, stmts) {
          ast.CaseClause(..c, body: ast.Block(c.body.span, stmts))
        }),
      )
    ast.Block(s, _), [stmts] -> ast.Block(s, stmts)
    _, _ -> e
  }
}

fn binds_any(stmts: List(Statement)) -> Bool {
  list.any(stmts, fn(s) {
    case s {
      ast.Assign(pattern:, ..) -> pattern_binds(pattern)
      ast.Use(patterns:, ..) ->
        list.any(patterns, fn(p) { pattern_binds(p.pattern) })
      _ -> False
    }
  })
}

pub fn pattern_binds(p: Pattern) -> Bool {
  case p {
    // Compiler generated names can't be referenced by user code.
    ast.PVar(_, name) if name != "" ->
      case synthetic(name) {
        True -> False
        False -> True
      }
    ast.PVar(..) | ast.PAssign(..) -> True
    ast.PInt(..) | ast.PFloat(..) | ast.PString(..) | ast.PDiscard(..) -> False
    ast.PTuple(_, ps) -> list.any(ps, pattern_binds)
    ast.PList(_, ps, t) -> list.any(list.append(ps, opt_list(t)), pattern_binds)
    ast.PConstructor(args:, ..) ->
      list.any(args, fn(a) {
        case a.value {
          None -> True
          Some(p) -> pattern_binds(p)
        }
      })
    ast.PConcat(_, _, name, rest) -> option.is_some(name) || pattern_binds(rest)
    ast.PBitArray(_, segs) -> list.any(segs, fn(s) { pattern_binds(s.value) })
  }
}

fn always_returns(stmts: List(Statement)) -> Bool {
  list.any(stmts, stmt_always_returns)
}

fn stmt_always_returns(stmt: Statement) -> Bool {
  case stmt {
    ast.Return(..) -> True
    ast.Expression(e) | ast.Assign(value: e, ..) -> expr_always_returns(e)
    _ -> False
  }
}

fn expr_always_returns(e: Expr) -> Bool {
  case e {
    // `panic` and `todo` never fall through either.
    ast.Panic(..) | ast.Todo(..) -> True
    ast.If(_, _, t, Some(el)) -> always_returns(t) && always_returns(el)
    ast.Case(_, _, clauses) ->
      clauses != []
      && list.all(clauses, fn(c) { always_returns(clause_stmts(c)) })
    ast.Block(_, stmts) -> always_returns(stmts)
    _ -> False
  }
}

fn has_return(stmt: Statement) -> Bool {
  case stmt {
    ast.Return(..) -> True
    ast.Guard(otherwise:, ..) ->
      list.any(otherwise.body, has_return)
      || list.any(statement_exprs(stmt), expr_has_return)
    _ -> list.any(statement_exprs(stmt), expr_has_return)
  }
}

fn expr_has_return(e: Expr) -> Bool {
  case e {
    ast.Fn(..) -> False
    ast.Block(_, stmts) -> list.any(stmts, has_return)
    ast.If(_, c, t, el) ->
      expr_has_return(c)
      || list.any(t, has_return)
      || list.any(option.unwrap(el, []), has_return)
    ast.Case(_, subjects, clauses) ->
      list.any(subjects, expr_has_return)
      || list.any(clauses, fn(c) { expr_has_return(c.body) })
    _ -> list.any(children(e), expr_has_return)
  }
}

// --- Validation ------------------------------------------------------------------

/// Any `return` still present after lowering sits somewhere it can't work,
/// e.g. inside a function argument.
fn leftover_returns(it: Item) -> List(Diagnostic) {
  case it {
    ast.Function(clauses: clauses, ..) ->
      list.flat_map(clauses, fn(c) {
        list.flat_map(option.unwrap(c.body, []), stmt_returns)
      })
    _ -> []
  }
}

fn stmt_returns(stmt: Statement) -> List(Diagnostic) {
  case stmt {
    ast.Return(s, _) -> [
      diagnostic.error("Unsupported return", s, "`return` can't be used here")
      |> diagnostic.with_hint(
        "A return must be a statement of a function body, or of an `if`, `case` or block at statement level.",
      ),
    ]
    _ -> list.flat_map(statement_exprs(stmt), expr_returns)
  }
}

fn expr_returns(e: Expr) -> List(Diagnostic) {
  case e {
    ast.Fn(_, _, _, body) -> list.flat_map(body, stmt_returns)
    ast.FnClauses(..) -> []
    ast.Block(_, stmts) -> list.flat_map(stmts, stmt_returns)
    ast.If(_, c, t, el) ->
      list.flatten([
        expr_returns(c),
        list.flat_map(t, stmt_returns),
        list.flat_map(option.unwrap(el, []), stmt_returns),
      ])
    _ -> list.flat_map(children(e), expr_returns)
  }
}

fn int_range(n: Int) -> List(Int) {
  do_range(n - 1, [])
}

fn do_range(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> do_range(i - 1, [i, ..acc])
  }
}

fn opt_list(o: Option(a)) -> List(a) {
  case o {
    Some(x) -> [x]
    None -> []
  }
}

/// `?` that survived hoisting is somewhere it can't be supported: a case
/// guard, a function guard or a constant.
fn leftover_tries(it: Item) -> List(Diagnostic) {
  case it {
    ast.Function(clauses: clauses, ..) ->
      list.flat_map(clauses, fn(c) {
        list.append(
          list.flat_map(opt_list(c.guard), expr_tries),
          list.flat_map(option.unwrap(c.body, []), fn(s) {
            list.flat_map(statement_exprs(s), expr_tries)
          }),
        )
      })
    ast.Const(value:, ..) -> expr_tries(value)
    _ -> []
  }
}

fn expr_tries(e: Expr) -> List(Diagnostic) {
  case e {
    ast.Try(s, _) -> [
      diagnostic.error("Unsupported `?`", s, "`?` can't be used here")
      |> diagnostic.with_hint(
        "`?` works inside function bodies, but not in guards or constants.",
      ),
    ]
    ast.Fn(_, _, _, body) ->
      list.flat_map(body, fn(s) {
        list.flat_map(statement_exprs(s), expr_tries)
      })
    ast.FnClauses(..) -> []
    _ -> list.flat_map(children(e), expr_tries)
  }
}

/// Names generated by lowering: `bea_try_12`, `bea_value_40`, ...
fn synthetic(name: String) -> Bool {
  let prefixes = [
    "bea_try_", "bea_ok_", "bea_error_", "bea_value_", "bea_val_", "bea_param_",
    "bea_continue_",
  ]
  list.any(prefixes, fn(prefix) {
    case string.starts_with(name, prefix) {
      True -> {
        let rest = string.drop_start(name, string.length(prefix))
        rest != ""
        && list.all(string.to_graphemes(rest), fn(c) {
          string.contains("0123456789", c)
        })
      }
      False -> False
    }
  })
}

/// A type written out without positions, for comparisons and messages.
fn type_key(t: ast.Type) -> String {
  case t {
    ast.NamedType(_, m, name, args) -> {
      let n = case m {
        Some(m) -> m <> "." <> name
        None -> name
      }
      case args {
        [] -> n
        _ -> n <> "(" <> string.join(list.map(args, type_key), ", ") <> ")"
      }
    }
    ast.VarType(_, n) | ast.HoleType(_, n) -> n
    ast.TupleType(_, ts) ->
      "(" <> string.join(list.map(ts, type_key), ", ") <> ")"
    ast.FnType(_, ps, r) ->
      "fn("
      <> string.join(list.map(ps, type_key), ", ")
      <> ") -> "
      <> type_key(r)
  }
}
