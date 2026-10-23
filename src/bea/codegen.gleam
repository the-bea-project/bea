//// Gleam code generation.
////
//// Takes a *lowered* module (see `bea/lower`) and prints Gleam source. Every
//// node is wrapped in a `doc.mark` so rendering also yields a source map from
//// generated Gleam back to the Bea source.
////
//// Imports are planned here: Bea auto-imports standard library modules that
//// are referenced (`list.map`), the common unqualified names (`Some`, `None`,
//// `Option`, `Dict`, ...), and the helper functions the lowering pass uses.
//// All of this is scope aware: a variable called `result` never gets mistaken
//// for the `gleam/result` module.

import bea/ast.{
  type Clause, type Expr, type Item, type Pattern, type Statement, type Type,
}
import bea/doc.{type Doc}
import bea/lexer
import bea/span.{type Span}
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/set.{type Set}
import gleam/string

/// What the code generator needs to know about the rest of the project.
pub type Context {
  Context(
    /// Constructors of single-variant custom types defined in other modules
    /// of the project (Bea modules, and Gleam modules such as code generated
    /// by tools), keyed by module path. Used to emit `let` instead of `let
    /// assert` for patterns that can't fail.
    single_constructors: Dict(String, Set(String)),
    /// The functions `@derive` defines in the project's Bea modules, keyed
    /// by module path (every Bea module has an entry, maybe empty), so a
    /// derived function can call the one of a field's type (see
    /// `bea/derive`).
    derived: Dict(String, List(Derived)),
    /// Type aliases of the project's Bea modules that mean the same in any
    /// module (they only name the prelude and the standard library), so a
    /// derived function can see through them: module path -> name ->
    /// (parameters, aliased type).
    aliases: Dict(String, Dict(String, #(List(String), ast.Type))),
  )
}

/// A function defined by `@derive` that other modules can call.
pub type Derived {
  Derived(
    type_name: String,
    /// Module path of the deriver.
    deriver: String,
    function: String,
    /// For each type parameter, whether the function takes an argument for
    /// it.
    capabilities: List(Bool),
    /// False for an opaque type: its derived functions are private.
    public: Bool,
  )
}

pub fn empty_context() -> Context {
  Context(dict.new(), dict.new(), dict.new())
}

pub type Output {
  Output(code: String, mappings: List(doc.Mapping))
}

pub fn generate(module: ast.Module, ctx: Context) -> Output {
  let plan = plan_imports(module, ctx)
  let doc = module_doc(module, plan)
  let #(code, mappings) = doc.render(doc, 80)
  Output(code <> "\n", mappings)
}

// --- Import planning ----------------------------------------------------------------

type Import {
  Import(
    module: String,
    alias: Option(String),
    unqualified: List(ast.Unqualified),
    span: Span,
    module_span: Span,
  )
}

type Plan {
  Plan(
    imports: List(Import),
    /// `$helper` placeholder -> Gleam reference
    helpers: Dict(String, String),
    /// Constructors (unqualified) whose type has exactly one variant.
    single: Set(String),
    /// Module alias -> single-variant constructors exported by it.
    single_qualified: Dict(String, Set(String)),
  )
}

/// Standard library modules Bea imports by itself when they are used:
/// (qualifier, module path).
pub const std_modules = [
  #("list", "gleam/list"),
  #("dict", "gleam/dict"),
  #("set", "gleam/set"),
  #("string", "gleam/string"),
  #("int", "gleam/int"),
  #("float", "gleam/float"),
  #("result", "gleam/result"),
  #("option", "gleam/option"),
  #("io", "gleam/io"),
  #("bool", "gleam/bool"),
  #("order", "gleam/order"),
  #("pair", "gleam/pair"),
  #("function", "gleam/function"),
  #("bit_array", "gleam/bit_array"),
  #("bytes_tree", "gleam/bytes_tree"),
  #("string_tree", "gleam/string_tree"),
  #("dynamic", "gleam/dynamic"),
  #("decode", "gleam/dynamic/decode"),
  #("uri", "gleam/uri"),
]

/// Unqualified names Bea imports automatically: (is_type, name, module).
const auto_unqualified = [
  #(True, "Option", "gleam/option"),
  #(False, "Some", "gleam/option"),
  #(False, "None", "gleam/option"),
  #(True, "Dict", "gleam/dict"),
  #(True, "Set", "gleam/set"),
  #(True, "Order", "gleam/order"),
  #(False, "Lt", "gleam/order"),
  #(False, "Eq", "gleam/order"),
  #(False, "Gt", "gleam/order"),
]

/// placeholder -> (module path, default qualifier, function)
const helper_functions = [
  #("$result.try", #("gleam/result", "result", "try")),
  #("$bool.guard", #("gleam/bool", "bool", "guard")),
  #("$bool.lazy_guard", #("gleam/bool", "bool", "lazy_guard")),
  #("$dict.from_list", #("gleam/dict", "dict", "from_list")),
  #("$dict.insert", #("gleam/dict", "dict", "insert")),
  #("$float.negate", #("gleam/float", "float", "negate")),
]

fn import_name(i: Import) -> String {
  case i.alias {
    Some(a) -> a
    None ->
      case string.split(i.module, "/") |> list.last {
        Ok(n) -> n
        Error(_) -> i.module
      }
  }
}

fn plan_imports(module: ast.Module, ctx: Context) -> Plan {
  let usage = collect(module)
  let user_imports =
    list.filter_map(module.items, fn(it) {
      case it {
        ast.Import(span, m, ms, alias, uq) ->
          Ok(Import(m, option.map(alias, fn(a) { a.0 }), uq, span, ms))
        _ -> Error(Nil)
      }
    })
  let imported_names = list.map(user_imports, import_name) |> set.from_list
  let imported_modules =
    list.map(user_imports, fn(i) { i.module }) |> set.from_list

  // 1. Standard library modules used by qualifier but not imported.
  let auto_modules =
    usage.modules
    |> set.to_list
    |> list.filter(fn(q) { !set.contains(imported_names, q) })
    |> list.filter_map(fn(q) { list.key_find(std_modules, q) })
    |> list.filter(fn(m) { !set.contains(imported_modules, m) })
    |> list.unique
    |> list.sort(string.compare)
    |> list.map(fn(m) { Import(m, None, [], span.empty, span.empty) })
  let imports = list.append(user_imports, auto_modules)

  // 2. Unqualified names like `Some` or `Dict`.
  let locally_defined = local_type_names(module)
  let unqualified_imported =
    list.flat_map(user_imports, fn(i) {
      list.map(i.unqualified, fn(u) {
        #(u.is_type, option.unwrap(u.alias, u.name))
      })
    })
    |> set.from_list
  let imports =
    list.fold(auto_unqualified, imports, fn(imports, entry) {
      let #(is_type, name, m) = entry
      let used = set.contains(usage.unqualified, #(is_type, name))
      let available =
        set.contains(locally_defined, name)
        || set.contains(unqualified_imported, #(is_type, name))
      case used && !available {
        True ->
          add_unqualified(
            imports,
            m,
            ast.Unqualified(span.empty, is_type, name, None),
          )
        False -> imports
      }
    })

  // 3. Helpers used by lowered code.
  let taken = set.union(usage.locals, module_values(module))
  let #(imports, helpers) =
    list.fold(helper_functions, #(imports, dict.new()), fn(acc, entry) {
      let #(imports, helpers) = acc
      let #(placeholder, #(m, qualifier, f)) = entry
      case set.contains(usage.helpers, placeholder) {
        False -> acc
        True -> {
          let existing = list.find(imports, fn(i) { i.module == m })
          let names = list.map(imports, import_name) |> set.from_list
          case existing {
            Ok(i) ->
              case set.contains(taken, import_name(i)) {
                False -> #(
                  imports,
                  dict.insert(helpers, placeholder, import_name(i) <> "." <> f),
                )
                True -> {
                  let alias = "bea_" <> qualifier <> "_" <> f
                  #(
                    add_unqualified(
                      imports,
                      m,
                      ast.Unqualified(span.empty, False, f, Some(alias)),
                    ),
                    dict.insert(helpers, placeholder, alias),
                  )
                }
              }
            Error(_) ->
              case
                set.contains(taken, qualifier) || set.contains(names, qualifier)
              {
                False -> #(
                  list.append(imports, [
                    Import(m, None, [], span.empty, span.empty),
                  ]),
                  dict.insert(helpers, placeholder, qualifier <> "." <> f),
                )
                True -> {
                  let alias = "bea_" <> qualifier <> "_" <> f
                  #(
                    list.append(imports, [
                      Import(
                        m,
                        // Only alias the module if its name is already
                        // used by another import (an unused alias warns).
                        case set.contains(names, qualifier) {
                          True -> Some("bea_" <> qualifier)
                          False -> None
                        },
                        [ast.Unqualified(span.empty, False, f, Some(alias))],
                        span.empty,
                        span.empty,
                      ),
                    ]),
                    dict.insert(helpers, placeholder, alias),
                  )
                }
              }
          }
        }
      }
    })

  // 4. Which constructors can't fail to match.
  let single = single_constructors(module)
  let single =
    list.fold(user_imports, single, fn(single, i) {
      case dict.get(ctx.single_constructors, i.module) {
        Ok(ctors) ->
          list.fold(i.unqualified, single, fn(single, u) {
            case !u.is_type && set.contains(ctors, u.name) {
              True -> set.insert(single, option.unwrap(u.alias, u.name))
              False -> single
            }
          })
        Error(_) -> single
      }
    })
    |> set.insert("Nil")
  let single_qualified =
    list.fold(user_imports, dict.new(), fn(acc, i) {
      case dict.get(ctx.single_constructors, i.module) {
        Ok(ctors) -> dict.insert(acc, import_name(i), ctors)
        Error(_) -> acc
      }
    })

  let imports =
    imports
    |> list.map(fn(i) {
      Import(
        ..i,
        unqualified: list.sort(i.unqualified, fn(a, b) {
          case a.is_type, b.is_type {
            True, False -> order.Lt
            False, True -> order.Gt
            _, _ -> string.compare(a.name, b.name)
          }
        }),
      )
    })
    |> list.sort(fn(a, b) { string.compare(a.module, b.module) })
  Plan(imports, helpers, single, single_qualified)
}

fn add_unqualified(
  imports: List(Import),
  m: String,
  u: ast.Unqualified,
) -> List(Import) {
  case list.any(imports, fn(i) { i.module == m }) {
    True ->
      list.map(imports, fn(i) {
        case i.module == m {
          True -> Import(..i, unqualified: list.append(i.unqualified, [u]))
          False -> i
        }
      })
    False ->
      list.append(imports, [Import(m, None, [u], span.empty, span.empty)])
  }
}

fn local_type_names(module: ast.Module) -> Set(String) {
  list.fold(module.items, set.new(), fn(acc, it) {
    case it {
      ast.CustomType(name:, variants:, ..) ->
        list.fold(variants, set.insert(acc, name), fn(acc, v) {
          set.insert(acc, v.name)
        })
      ast.TypeAlias(name:, ..) | ast.ExternalType(name:, ..) ->
        set.insert(acc, name)
      _ -> acc
    }
  })
}

fn module_values(module: ast.Module) -> Set(String) {
  list.fold(module.items, set.new(), fn(acc, it) {
    case it {
      ast.Function(name:, ..) | ast.Const(name:, ..) -> set.insert(acc, name)
      ast.Import(unqualified:, ..) ->
        list.fold(unqualified, acc, fn(acc, u) {
          case u.is_type {
            True -> acc
            False -> set.insert(acc, option.unwrap(u.alias, u.name))
          }
        })
      _ -> acc
    }
  })
}

fn single_constructors(module: ast.Module) -> Set(String) {
  list.fold(module.items, set.new(), fn(acc, it) {
    case it {
      ast.CustomType(variants: [v], ..) -> set.insert(acc, v.name)
      _ -> acc
    }
  })
}

/// Public so the project compiler can build a `Context`.
pub fn exported_single_constructors(module: ast.Module) -> Set(String) {
  list.fold(module.items, set.new(), fn(acc, it) {
    case it {
      ast.CustomType(variants: [v], publicity: ast.Public, opaque_: False, ..) ->
        set.insert(acc, v.name)
      _ -> acc
    }
  })
}

/// The same for a Gleam module of the project, hand written or generated by
/// a tool (e.g. Marmot's row types), read from its source. Gleam's tokens
/// are a subset of Bea's, so the Bea lexer reads it; only the headers and
/// bodies of `pub type` declarations matter. Anything unexpected makes it
/// report less, never more: a constructor missing here only means `let
/// assert` where `let` would do, but one wrongly here would not compile.
pub fn gleam_single_constructors(source: String) -> Set(String) {
  let lexed = lexer.lex(source)
  case lexed.errors {
    [] -> scan_gleam_types(list.map(lexed.tokens, fn(t) { t.kind }), set.new())
    _ -> set.new()
  }
}

fn scan_gleam_types(tokens: List(lexer.Kind), acc: Set(String)) -> Set(String) {
  case tokens {
    [] -> acc
    [lexer.Pub, lexer.Type, lexer.UpName(_), ..rest] -> {
      // Skip the type's parameters: `pub type Pair(a, b) {`.
      let rest = case rest {
        [lexer.LParen, ..after] -> skip_parens(after, 0)
        _ -> rest
      }
      case rest {
        [lexer.LBrace, ..body] -> {
          let #(constructors, rest) = gleam_constructors(body, 0, [])
          case constructors {
            Ok([name]) -> scan_gleam_types(rest, set.insert(acc, name))
            _ -> scan_gleam_types(rest, acc)
          }
        }
        // An alias (`= ...`) or an external type.
        _ -> scan_gleam_types(rest, acc)
      }
    }
    [_, ..rest] -> scan_gleam_types(rest, acc)
  }
}

fn skip_parens(tokens: List(lexer.Kind), depth: Int) -> List(lexer.Kind) {
  case tokens {
    [] -> []
    [lexer.RParen, ..rest] if depth == 0 -> rest
    [lexer.RParen, ..rest] -> skip_parens(rest, depth - 1)
    [lexer.LParen, ..rest] -> skip_parens(rest, depth + 1)
    [_, ..rest] -> skip_parens(rest, depth)
  }
}

/// The constructors in a custom type's body, up to its closing `}`: the
/// capitalised names outside parentheses (fields and their types, and the
/// arguments of attributes such as `@deprecated(...)`, are all inside).
fn gleam_constructors(
  tokens: List(lexer.Kind),
  depth: Int,
  acc: List(String),
) -> #(Result(List(String), Nil), List(lexer.Kind)) {
  case tokens {
    [] -> #(Error(Nil), [])
    [lexer.RBrace, ..rest] if depth == 0 -> #(Ok(acc), rest)
    // Not a custom type body after all; don't guess.
    [lexer.LBrace, ..rest] | [lexer.RBrace, ..rest] -> #(Error(Nil), rest)
    [lexer.LParen, ..rest] -> gleam_constructors(rest, depth + 1, acc)
    [lexer.RParen, ..rest] -> gleam_constructors(rest, depth - 1, acc)
    [lexer.UpName(name), ..rest] if depth == 0 ->
      gleam_constructors(rest, depth, [name, ..acc])
    [_, ..rest] -> gleam_constructors(rest, depth, acc)
  }
}

// --- Usage collection (scope aware) ---------------------------------------------------

type Usage {
  Usage(
    modules: Set(String),
    unqualified: Set(#(Bool, String)),
    helpers: Set(String),
    locals: Set(String),
    /// `module.member` references: (qualifier, member).
    members: Set(#(String, String)),
    /// Lower case names used without being bound locally (module functions
    /// and constants, unqualified imports).
    values: Set(String),
  )
}

/// What a module refers to by name, for organising its imports.
pub type References {
  References(
    /// Qualifiers used as modules: `list` in `list.map`, types, patterns.
    modules: Set(String),
    /// (qualifier, member) pairs: `#("list", "map")`, `#("request", "Request")`.
    members: Set(#(String, String)),
    /// Unqualified types (`#(True, "Dict")`) and constructors
    /// (`#(False, "Some")`).
    unqualified: Set(#(Bool, String)),
    /// Lower case names that aren't local variables.
    values: Set(String),
  )
}

/// The names a (not yet lowered) module refers to, scope aware: a variable
/// called `list` is not the `list` module.
pub fn references(module: ast.Module) -> References {
  let u = collect(module)
  References(u.modules, u.members, u.unqualified, u.values)
}

fn add_member(u: Usage, m: String, name: String) -> Usage {
  Usage(
    ..u,
    modules: set.insert(u.modules, m),
    members: set.insert(u.members, #(m, name)),
  )
}

fn collect(module: ast.Module) -> Usage {
  let u =
    Usage(set.new(), set.new(), set.new(), set.new(), set.new(), set.new())
  list.fold(module.items, u, fn(u, it) {
    case it {
      ast.Function(clauses:, ..) ->
        list.fold(clauses, u, fn(u, c) {
          let u =
            list.fold(c.params, u, fn(u, p) {
              u_type_opt(u, p.annotation) |> u_pattern(p.pattern)
            })
          let u = u_type_opt(u, c.return_type)
          let scope =
            list.fold(c.params, set.new(), fn(s, p) { bind(s, p.pattern) })
          let u = case c.guard {
            Some(g) -> u_expr(u, scope, g)
            None -> u
          }
          u_stmts(u, scope, option.unwrap(c.body, []))
        })
      ast.Const(annotation:, value:, ..) ->
        u_type_opt(u, annotation) |> u_expr(set.new(), value)
      ast.CustomType(variants:, attributes:, ..) ->
        list.fold(variants, u, fn(u, v) {
          list.fold(v.fields, u, fn(u, f) { u_type(u, f.type_) })
        })
        // `@derive(decoder)` uses the module `decoder`.
        |> list.fold(derivers(attributes), _, fn(u, m) {
          Usage(..u, modules: set.insert(u.modules, m))
        })
      ast.TypeAlias(aliased:, ..) -> u_type(u, aliased)
      _ -> u
    }
  })
}

/// The modules named by `@derive(...)` attributes.
pub fn derivers(attributes: List(ast.Attribute)) -> List(String) {
  list.flat_map(attributes, fn(a) {
    case a.name {
      "derive" ->
        list.filter_map(a.args, fn(arg) {
          case arg {
            ast.AttrName(n, _) -> Ok(n)
            ast.AttrString(_) -> Error(Nil)
          }
        })
      _ -> []
    }
  })
}

/// `scope` with the variables `p` binds.
pub fn bind(scope: Set(String), p: Pattern) -> Set(String) {
  case p {
    ast.PVar(_, n) -> set.insert(scope, n)
    ast.PAssign(_, inner, n) -> bind(set.insert(scope, n), inner)
    ast.PTuple(_, ps) -> list.fold(ps, scope, bind)
    ast.PList(_, ps, t) ->
      list.fold(list.append(ps, option.values([t])), scope, bind)
    ast.PConstructor(args:, ..) ->
      list.fold(args, scope, fn(s, a) {
        case a.value, a.label {
          Some(v), _ -> bind(s, v)
          None, Some(l) -> set.insert(s, l)
          None, None -> s
        }
      })
    ast.PConcat(_, _, name, rest) -> {
      let s = case name {
        Some(n) -> set.insert(scope, n)
        None -> scope
      }
      bind(s, rest)
    }
    ast.PBitArray(_, segs) ->
      list.fold(segs, scope, fn(s, seg) { bind(s, seg.value) })
    _ -> scope
  }
}

fn u_pattern(u: Usage, p: Pattern) -> Usage {
  let u = Usage(..u, locals: bind(u.locals, p))
  case p {
    ast.PConstructor(module: None, name:, args:, ..) ->
      list.fold(args, add_unq(u, False, name), fn(u, a) {
        case a.value {
          Some(v) -> u_pattern(u, v)
          None -> u
        }
      })
    ast.PConstructor(module: Some(m), name:, args:, ..) ->
      list.fold(args, add_member(u, m, name), fn(u, a) {
        case a.value {
          Some(v) -> u_pattern(u, v)
          None -> u
        }
      })
    ast.PAssign(_, inner, _) -> u_pattern(u, inner)
    ast.PTuple(_, ps) -> list.fold(ps, u, u_pattern)
    ast.PList(_, ps, t) ->
      list.fold(list.append(ps, option.values([t])), u, u_pattern)
    ast.PConcat(_, _, _, rest) -> u_pattern(u, rest)
    ast.PBitArray(_, segs) ->
      list.fold(segs, u, fn(u, s) {
        list.fold(s.options, u_pattern(u, s.value), fn(u, o) {
          case o.arg {
            Some(a) -> u_pattern(u, a)
            None -> u
          }
        })
      })
    _ -> u
  }
}

fn add_unq(u: Usage, is_type: Bool, name: String) -> Usage {
  Usage(..u, unqualified: set.insert(u.unqualified, #(is_type, name)))
}

fn u_type_opt(u: Usage, t: Option(Type)) -> Usage {
  case t {
    Some(t) -> u_type(u, t)
    None -> u
  }
}

fn u_type(u: Usage, t: Type) -> Usage {
  case t {
    ast.NamedType(_, None, name, args) ->
      list.fold(args, add_unq(u, True, name), u_type)
    ast.NamedType(_, Some(m), name, args) ->
      list.fold(args, add_member(u, m, name), u_type)
    ast.TupleType(_, ts) -> list.fold(ts, u, u_type)
    ast.FnType(_, ps, r) -> u_type(list.fold(ps, u, u_type), r)
    _ -> u
  }
}

fn u_stmts(u: Usage, scope: Set(String), stmts: List(Statement)) -> Usage {
  case stmts {
    [] -> u
    [stmt, ..rest] ->
      case stmt {
        ast.Assign(_, p, t, v) -> {
          let u = u_expr(u, scope, v) |> u_type_opt(t) |> u_pattern(p)
          u_stmts(u, bind(scope, p), rest)
        }
        ast.Use(_, ps, call) -> {
          let u = u_expr(u, scope, call)
          let u =
            list.fold(ps, u, fn(u, p) {
              u_pattern(u, p.pattern) |> u_type_opt(p.annotation)
            })
          let scope = list.fold(ps, scope, fn(s, p) { bind(s, p.pattern) })
          u_stmts(u, scope, rest)
        }
        ast.Expression(e) | ast.Return(_, e) ->
          u_stmts(u_expr(u, scope, e), scope, rest)
        ast.Assert(_, e, m) -> {
          let u = u_expr(u, scope, e)
          let u = case m {
            Some(m) -> u_expr(u, scope, m)
            None -> u
          }
          u_stmts(u, scope, rest)
        }
        ast.Guard(_, p, t, v, otherwise) -> {
          let u = u_expr(u, scope, v) |> u_type_opt(t)
          let #(u, else_scope) = case otherwise.binding {
            Some(b) -> #(u_pattern(u, b), bind(scope, b))
            None -> #(u, scope)
          }
          let u = u_stmts(u, else_scope, otherwise.body)
          let #(u, scope) = case p {
            Some(p) -> #(u_pattern(u, p), bind(scope, p))
            None -> #(u, scope)
          }
          u_stmts(u, scope, rest)
        }
      }
  }
}

fn u_expr(u: Usage, scope: Set(String), e: Expr) -> Usage {
  let go = fn(u, x) { u_expr(u, scope, x) }
  case e {
    ast.Var(_, n) ->
      case string.starts_with(n, "$"), set.contains(scope, n) {
        True, _ -> Usage(..u, helpers: set.insert(u.helpers, n))
        False, False -> Usage(..u, values: set.insert(u.values, n))
        False, True -> u
      }
    ast.Constructor(_, None, n) -> add_unq(u, False, n)
    ast.Constructor(_, Some(m), n) -> add_member(u, m, n)
    // `Credentials.decoder()` uses the type `Credentials` (see
    // `bea/associated`), not its constructor.
    ast.FieldAccess(_, ast.Constructor(_, None, t), _, _) -> add_unq(u, True, t)
    ast.FieldAccess(_, ast.Constructor(_, Some(m), t), _, _) ->
      add_member(u, m, t)
    ast.FieldAccess(_, ast.Var(_, m), field, _) ->
      case set.contains(scope, m) {
        True -> u
        False -> add_member(u, m, field)
      }
    ast.Int(..) | ast.Float(..) | ast.RawString(..) | ast.Hole(..) -> u
    ast.String(_, parts) ->
      list.fold(parts, u, fn(u, p) {
        case p {
          ast.Interpolation(x, _) -> go(u, x)
          _ -> u
        }
      })
    ast.FieldAccess(_, b, _, _) | ast.TupleIndex(_, b, _) -> go(u, b)
    ast.Call(_, f, args) ->
      list.fold(arg_values(args), go(u, f), go) |> u_shorthand(scope, args)
    ast.RecordUpdate(_, c, b, args) ->
      list.fold(arg_values(args), go(go(u, c), b), go)
      |> u_shorthand(scope, args)
    ast.Tuple(_, es) -> list.fold(es, u, go)
    ast.List(_, es, t) -> list.fold(list.append(es, option.values([t])), u, go)
    ast.Map(_, b, pairs) -> {
      let u =
        Usage(..u, helpers: case b {
          Some(_) -> set.insert(u.helpers, "$dict.insert")
          None -> set.insert(u.helpers, "$dict.from_list")
        })
      let u = list.fold(option.values([b]), u, go)
      list.fold(pairs, u, fn(u, kv) { go(go(u, kv.0), kv.1) })
    }
    ast.Fn(_, params, ret, body) -> {
      let u =
        list.fold(params, u, fn(u, p) {
          u_pattern(u, p.pattern) |> u_type_opt(p.annotation)
        })
      let u = u_type_opt(u, ret)
      let inner = list.fold(params, scope, fn(s, p) { bind(s, p.pattern) })
      u_stmts(u, inner, body)
    }
    ast.FnClauses(_, clauses) -> {
      list.fold(clauses, u, fn(u, c) {
        let inner =
          list.fold(c.alternatives, scope, fn(s, alt) {
            list.fold(alt, s, bind)
          })
        let u =
          list.fold(c.alternatives, u, fn(u, alt) {
            list.fold(alt, u, u_pattern)
          })
        let u = case c.guard {
          Some(g) -> u_expr(u, inner, g)
          None -> u
        }
        u_expr(u, inner, c.body)
      })
    }
    ast.Block(_, stmts) -> u_stmts(u, scope, stmts)
    ast.If(_, c, t, el) -> {
      let u = u_stmts(go(u, c), scope, t)
      case el {
        Some(el) -> u_stmts(u, scope, el)
        None -> u
      }
    }
    ast.Cond(_, clauses) ->
      list.fold(clauses, u, fn(u, c) { go(go(u, c.condition), c.body) })
    ast.Case(_, subjects, clauses) -> {
      let u = list.fold(subjects, u, go)
      list.fold(clauses, u, fn(u, c) {
        let inner =
          list.fold(c.alternatives, scope, fn(s, alt) {
            list.fold(alt, s, bind)
          })
        let u =
          list.fold(c.alternatives, u, fn(u, alt) {
            list.fold(alt, u, u_pattern)
          })
        let u = case c.guard {
          Some(g) -> u_expr(u, inner, g)
          None -> u
        }
        u_expr(u, inner, c.body)
      })
    }
    ast.BinaryOp(_, _, l, r) -> go(go(u, l), r)
    ast.Negate(_, x) | ast.Not(_, x) | ast.Try(_, x) -> go(u, x)
    ast.NegateFloat(_, x) ->
      go(Usage(..u, helpers: set.insert(u.helpers, "$float.negate")), x)
    ast.Echo(_, x, m) -> list.fold(option.values([x, m]), u, go)
    ast.Panic(_, m) | ast.Todo(_, m) -> list.fold(option.values([m]), u, go)
    ast.BitArray(_, segs) ->
      list.fold(segs, u, fn(u, s) {
        list.fold(
          option.values(list.map(s.options, fn(o) { o.arg })),
          go(u, s.value),
          go,
        )
      })
  }
}

fn arg_values(args: List(ast.Arg)) -> List(Expr) {
  option.values(list.map(args, fn(a) { a.value }))
}

/// `f(label:)` passes the variable `label`.
fn u_shorthand(u: Usage, scope: Set(String), args: List(ast.Arg)) -> Usage {
  list.fold(args, u, fn(u, a) {
    case a.label, a.value {
      Some(l), None ->
        case set.contains(scope, l) {
          True -> u
          False -> Usage(..u, values: set.insert(u.values, l))
        }
      _, _ -> u
    }
  })
}

// --- Printing -----------------------------------------------------------------------

fn t(s: String) -> Doc {
  doc.text(s)
}

fn mk(d: Doc, s: Span) -> Doc {
  case s == span.empty {
    True -> d
    False -> doc.mark(d, s)
  }
}

fn module_doc(module: ast.Module, plan: Plan) -> Doc {
  let header = list.map(module.module_doc, fn(line) { t("////" <> line) })
  let imports = list.map(plan.imports, import_doc)
  let items =
    module.items
    |> list.filter(fn(it) {
      case it {
        ast.Import(..) -> False
        _ -> True
      }
    })
    |> list.map(item_doc(_, plan))
  let sections =
    [header, imports, items]
    |> list.filter(fn(s) { s != [] })
    |> list.map(fn(section) {
      case section == items {
        True -> doc.join(section, doc.concat([doc.hard_line, doc.hard_line]))
        False -> doc.join(section, doc.hard_line)
      }
    })
  doc.join(sections, doc.concat([doc.hard_line, doc.hard_line]))
}

fn import_doc(i: Import) -> Doc {
  let uq = case i.unqualified {
    [] -> doc.empty
    uqs ->
      doc.concat([
        t("."),
        doc.comma_list(
          "{",
          list.map(uqs, fn(u) {
            let name = case u.is_type {
              True -> "type " <> u.name
              False -> u.name
            }
            case u.alias {
              Some(a) -> t(name <> " as " <> a)
              None -> t(name)
            }
            |> mk(u.span)
          }),
          "}",
        ),
      ])
  }
  let alias = case i.alias {
    Some(a) -> t(" as " <> a)
    None -> doc.empty
  }
  doc.concat([t("import "), t(i.module) |> mk(i.module_span), uq, alias])
  |> mk(i.span)
}

fn publicity(p: ast.Publicity) -> Doc {
  case p {
    ast.Public -> t("pub ")
    ast.Private -> doc.empty
  }
}

fn docs(lines: List(String)) -> Doc {
  doc.concat(
    list.map(lines, fn(l) { doc.concat([t("///" <> l), doc.hard_line]) }),
  )
}

fn attributes(attrs: List(ast.Attribute)) -> Doc {
  doc.concat(
    list.map(attrs, fn(a) {
      let args = case a.args {
        [] -> doc.empty
        args ->
          doc.comma_list(
            "(",
            list.map(args, fn(arg) {
              case arg {
                ast.AttrName(n, _) -> t(n)
                ast.AttrString(s) -> t("\"" <> s <> "\"")
              }
            }),
            ")",
          )
      }
      doc.concat([t("@" <> a.name) |> mk(a.span), args, doc.hard_line])
    }),
  )
}

fn item_doc(it: Item, plan: Plan) -> Doc {
  case it {
    ast.Function(_, name, _, clauses) ->
      case clauses {
        [c] -> function_doc(name, c, plan)
        // Not lowered (only happens if lowering reported errors).
        _ -> t("// invalid function " <> name)
      }
    ast.CustomType(
      span,
      d,
      attrs,
      p,
      opaque_,
      name,
      name_span,
      params,
      variants,
    ) -> {
      let head =
        doc.concat([
          docs(d),
          attributes(attrs),
          publicity(p),
          case opaque_ {
            True -> t("opaque ")
            False -> doc.empty
          },
          t("type "),
          t(name) |> mk(name_span),
          type_params(params),
        ])
      let body = case variants {
        [] -> t(" {}")
        _ ->
          doc.concat([
            t(" {"),
            doc.nest(
              doc.concat(
                list.map(variants, fn(v) {
                  doc.concat([doc.hard_line, variant_doc(v)])
                }),
              ),
              2,
            ),
            doc.hard_line,
            t("}"),
          ])
      }
      doc.concat([head, body]) |> mk(span)
    }
    ast.TypeAlias(span, d, attrs, p, name, name_span, params, aliased) ->
      doc.concat([
        docs(d),
        attributes(attrs),
        publicity(p),
        t("type "),
        t(name) |> mk(name_span),
        type_params(params),
        t(" ="),
        doc.nest(doc.concat([doc.hard_line, type_doc(aliased)]), 2),
      ])
      |> mk(span)
    ast.ExternalType(span, d, attrs, p, name, name_span, params) ->
      doc.concat([
        docs(d),
        attributes(attrs),
        publicity(p),
        t("type "),
        t(name) |> mk(name_span),
        type_params(params),
      ])
      |> mk(span)
    ast.Const(span, d, attrs, p, name, name_span, annotation, value) ->
      doc.concat([
        docs(d),
        attributes(attrs),
        publicity(p),
        t("const "),
        t(name) |> mk(name_span),
        annotation_doc(annotation),
        t(" = "),
        expr(value, plan),
      ])
      |> mk(span)
    ast.Import(..) -> doc.empty
  }
}

fn type_params(params: List(String)) -> Doc {
  case params {
    [] -> doc.empty
    _ -> t("(" <> string.join(params, ", ") <> ")")
  }
}

fn variant_doc(v: ast.Variant) -> Doc {
  let fields = case v.fields {
    [] -> doc.empty
    fs ->
      doc.comma_list(
        "(",
        list.map(fs, fn(f) {
          case f.label {
            Some(l) -> doc.concat([t(l <> ": "), type_doc(f.type_)])
            None -> type_doc(f.type_)
          }
          |> mk(f.span)
        }),
        ")",
      )
  }
  doc.concat([docs(v.doc), t(v.name), fields]) |> mk(v.span)
}

fn annotation_doc(t_: Option(Type)) -> Doc {
  case t_ {
    Some(ty) -> doc.concat([t(": "), type_doc(ty)])
    None -> doc.empty
  }
}

fn type_doc(ty: Type) -> Doc {
  case ty {
    ast.NamedType(s, m, name, args) -> {
      let n = case m {
        Some(m) -> m <> "." <> name
        None -> name
      }
      case args {
        [] -> t(n)
        _ -> doc.concat([t(n), flat_list("(", list.map(args, type_doc), ")")])
      }
      |> mk(s)
    }
    ast.VarType(s, n) -> t(n) |> mk(s)
    ast.HoleType(s, n) -> t(n) |> mk(s)
    ast.TupleType(s, ts) ->
      flat_list("#(", list.map(ts, type_doc), ")") |> mk(s)
    ast.FnType(s, ps, r) ->
      doc.concat([
        t("fn"),
        flat_list("(", list.map(ps, type_doc), ")"),
        t(" -> "),
        type_doc(r),
      ])
      |> mk(s)
  }
}

fn function_doc(name: String, c: Clause, plan: Plan) -> Doc {
  let params =
    list.map(c.params, fn(p) {
      doc.concat([
        case p.label {
          Some(l) -> t(l <> " ")
          None -> doc.empty
        },
        pattern(p.pattern, plan),
        annotation_doc(p.annotation),
      ])
      |> mk(p.span)
    })
  let ret = case c.return_type {
    Some(r) -> doc.concat([t(" -> "), type_doc(r)])
    None -> doc.empty
  }
  let body = case c.body {
    Some(stmts) -> doc.concat([t(" "), block(stmts, plan)])
    None -> doc.empty
  }
  doc.concat([
    docs(c.doc),
    attributes(c.attributes),
    publicity(c.publicity),
    t("fn "),
    t(name) |> mk(c.name_span),
    doc.comma_list("(", params, ")"),
    ret,
    body,
  ])
  |> mk(c.span)
}

/// `{ ... }` with one statement per line.
fn block(stmts: List(Statement), plan: Plan) -> Doc {
  case stmts {
    [] -> t("{ Nil }")
    _ ->
      doc.concat([
        t("{"),
        doc.nest(doc.concat([doc.hard_line, statements(stmts, plan)]), 2),
        doc.hard_line,
        t("}"),
      ])
  }
}

/// A block that may stay on one line if it's a single short expression.
fn soft_block(stmts: List(Statement), plan: Plan) -> Doc {
  case stmts {
    [ast.Expression(e)] ->
      doc.group(
        doc.concat([
          t("{"),
          doc.nest(doc.concat([doc.line, expr(e, plan)]), 2),
          doc.line,
          t("}"),
        ]),
      )
    _ -> block(stmts, plan)
  }
}

fn statements(stmts: List(Statement), plan: Plan) -> Doc {
  doc.join(list.map(stmts, statement(_, plan)), doc.hard_line)
}

fn statement(stmt: Statement, plan: Plan) -> Doc {
  case stmt {
    ast.Assign(s, p, annotation, value) -> {
      let assert_ = case irrefutable(p, plan) || same_constructor(p, value) {
        True -> "let "
        False -> "let assert "
      }
      doc.concat([
        t(assert_),
        pattern(p, plan),
        annotation_doc(annotation),
        t(" ="),
        assigned(value, plan),
      ])
      |> mk(s)
    }
    ast.Expression(e) -> expr(e, plan)
    // Only reachable when lowering failed and reported an error.
    ast.Return(s, e) -> expr(e, plan) |> mk(s)
    ast.Use(s, ps, call) -> {
      let pats = case ps {
        [] -> t("use <- ")
        _ ->
          doc.concat([
            t("use "),
            doc.join(
              list.map(ps, fn(p) {
                doc.concat([
                  pattern(p.pattern, plan),
                  annotation_doc(p.annotation),
                ])
                |> mk(p.span)
              }),
              t(", "),
            ),
            t(" <- "),
          ])
      }
      doc.concat([pats, expr(call, plan)]) |> mk(s)
    }
    ast.Assert(s, e, m) ->
      doc.concat([
        t("assert "),
        expr(e, plan),
        case m {
          Some(m) -> doc.concat([t(" as "), expr(m, plan)])
          None -> doc.empty
        },
      ])
      |> mk(s)
    // Guards are lowered to `case`s; only reachable when lowering failed
    // and reported an error.
    ast.Guard(s, _, _, value, _) -> expr(value, plan) |> mk(s)
  }
}

fn irrefutable(p: Pattern, plan: Plan) -> Bool {
  case p {
    ast.PVar(..) | ast.PDiscard(..) -> True
    ast.PAssign(_, inner, _) -> irrefutable(inner, plan)
    ast.PTuple(_, ps) -> list.all(ps, irrefutable(_, plan))
    ast.PConstructor(_, module, name, args, _) -> {
      let single = case module {
        None -> set.contains(plan.single, name)
        Some(m) ->
          case dict.get(plan.single_qualified, m) {
            Ok(ctors) -> set.contains(ctors, name)
            Error(_) -> False
          }
      }
      single
      && list.all(args, fn(a) {
        case a.value {
          Some(v) -> irrefutable(v, plan)
          None -> True
        }
      })
    }
    _ -> False
  }
}

// --- Expressions ----------------------------------------------------------------------

/// Precedence of an expression when used as an operand; 100 means atomic.
fn expr_precedence(e: Expr) -> Int {
  case e {
    ast.BinaryOp(_, op, _, _) -> ast.precedence(op)
    ast.Echo(_, None, _) -> 100
    ast.Echo(..) | ast.Panic(..) | ast.Todo(..) -> 0
    _ -> 100
  }
}

fn operand(e: Expr, min: Int, plan: Plan) -> Doc {
  case expr_precedence(e) < min {
    True -> doc.concat([t("{ "), expr(e, plan), t(" }")])
    False -> expr(e, plan)
  }
}

fn expr(e: Expr, plan: Plan) -> Doc {
  expr_inner(e, plan) |> mk(e.span)
}

fn expr_inner(e: Expr, plan: Plan) -> Doc {
  case e {
    ast.Int(_, text) | ast.Float(_, text) -> t(text)
    ast.String(_, parts) -> string_doc(parts, plan)
    ast.RawString(_, v) -> t("\"" <> lexer.escape_gleam_string(v) <> "\"")
    ast.Var(_, n) ->
      case dict.get(plan.helpers, n) {
        Ok(reference) -> t(reference)
        Error(_) -> t(n)
      }
    ast.Constructor(_, Some(m), n) -> t(m <> "." <> n)
    ast.Constructor(_, None, n) -> t(n)
    ast.Hole(_) -> t("_")
    ast.FieldAccess(_, base, field, fs) ->
      doc.concat([operand(base, 100, plan), t("."), t(field) |> mk(fs)])
    ast.TupleIndex(_, base, i) ->
      doc.concat([operand(base, 100, plan), t("." <> int.to_string(i))])
    ast.Call(_, f, args) -> {
      let callee = case f {
        ast.Var(..)
        | ast.FieldAccess(..)
        | ast.Constructor(..)
        | ast.Call(..)
        | ast.TupleIndex(..) -> expr(f, plan)
        _ -> doc.concat([t("{ "), expr(f, plan), t(" }")])
      }
      doc.concat([
        callee,
        doc.comma_list("(", list.map(args, arg(_, plan)), ")"),
      ])
    }
    ast.RecordUpdate(_, c, base, updates) ->
      doc.concat([
        expr(c, plan),
        doc.comma_list(
          "(",
          [
            doc.concat([t(".."), expr(base, plan)]),
            ..list.map(updates, arg(_, plan))
          ],
          ")",
        ),
      ])
    ast.Tuple(_, es) -> doc.comma_list("#(", list.map(es, expr(_, plan)), ")")
    ast.List(_, es, tail) -> {
      let tail = case tail {
        Some(tl) -> [doc.concat([t(".."), expr(tl, plan)])]
        None -> []
      }
      doc.comma_list("[", list.append(list.map(es, expr(_, plan)), tail), "]")
    }
    ast.Map(s, None, pairs) -> {
      let from_list = helper(plan, "$dict.from_list")
      doc.concat([
        t(from_list),
        t("("),
        doc.comma_list("[", list.map(pairs, pair_doc(_, plan)), "]"),
        t(")"),
      ])
      |> mk(s)
    }
    ast.Map(_, Some(base), pairs) -> {
      let insert = helper(plan, "$dict.insert")
      list.fold(pairs, expr(base, plan), fn(acc, kv) {
        doc.concat([
          t(insert),
          doc.comma_list("(", [acc, expr(kv.0, plan), expr(kv.1, plan)], ")"),
        ])
      })
    }
    ast.Fn(_, params, ret, body) -> {
      let params =
        list.map(params, fn(p) {
          doc.concat([pattern(p.pattern, plan), annotation_doc(p.annotation)])
          |> mk(p.span)
        })
      doc.concat([
        t("fn"),
        doc.comma_list("(", params, ")"),
        case ret {
          Some(r) -> doc.concat([t(" -> "), type_doc(r)])
          None -> doc.empty
        },
        t(" "),
        soft_block(body, plan),
      ])
    }
    ast.Block(_, stmts) -> soft_block(stmts, plan)
    ast.If(_, c, then, el) -> {
      let false_branch = case el {
        Some(stmts) -> branch(stmts, plan)
        None -> t(" Nil")
      }
      case_doc([expr(c, plan)], [
        doc.concat([t("True ->"), branch(then, plan)]),
        doc.concat([t("False ->"), false_branch]),
      ])
    }
    ast.Cond(..) | ast.FnClauses(..) ->
      t("todo as \"should have been lowered\"")
    ast.Case(_, subjects, clauses) ->
      case_doc(
        list.map(subjects, expr(_, plan)),
        list.map(clauses, case_clause(_, plan)),
      )
    ast.BinaryOp(_, ast.Pipe, _, _) -> {
      // Like `gleam format`: a pipeline is either on one line, or has every
      // step on its own line.
      let #(first, steps) = pipe_chain(e, [])
      let p = ast.precedence(ast.Pipe)
      doc.group(
        doc.concat([
          operand(first, p, plan),
          ..list.map(steps, fn(step) {
            doc.concat([doc.line, t("|> "), operand(step, p + 1, plan)])
          })
        ]),
      )
    }
    ast.BinaryOp(_, op, l, r) -> {
      let p = ast.precedence(op)
      doc.concat([
        operand(l, p, plan),
        t(" " <> ast.binop_to_string(op) <> " "),
        operand(r, p + 1, plan),
      ])
    }
    ast.Negate(_, x) ->
      case x {
        // `- -5` is not valid Gleam.
        ast.Int(_, "-" <> _) | ast.Float(_, "-" <> _) ->
          doc.concat([t("-{ "), expr(x, plan), t(" }")])
        _ -> doc.concat([t("-"), operand(x, 100, plan)])
      }
    ast.NegateFloat(_, x) ->
      doc.concat([
        t(helper(plan, "$float.negate") <> "("),
        expr(x, plan),
        t(")"),
      ])
    ast.Not(_, x) -> doc.concat([t("!"), operand(x, 100, plan)])
    ast.Echo(_, None, _) -> t("echo")
    ast.Echo(_, Some(x), m) ->
      doc.concat([
        t("echo "),
        expr(x, plan),
        case m {
          Some(m) -> doc.concat([t(" as "), expr(m, plan)])
          None -> doc.empty
        },
      ])
    // Only reachable when lowering reported an error.
    ast.Try(_, x) -> expr(x, plan)
    ast.Panic(_, m) -> keyword_message("panic", m, plan)
    ast.Todo(_, m) -> keyword_message("todo", m, plan)
    ast.BitArray(_, segs) ->
      doc.comma_list("<<", list.map(segs, segment(_, expr(_, plan))), ">>")
  }
}

fn helper(plan: Plan, name: String) -> String {
  dict.get(plan.helpers, name) |> result.unwrap(string.drop_start(name, 1))
}

fn keyword_message(kw: String, m: Option(Expr), plan: Plan) -> Doc {
  case m {
    Some(m) -> doc.concat([t(kw <> " as "), operand(m, 100, plan)])
    None -> t(kw)
  }
}

fn pair_doc(kv: #(Expr, Expr), plan: Plan) -> Doc {
  doc.comma_list("#(", [expr(kv.0, plan), expr(kv.1, plan)], ")")
}

fn arg(a: ast.Arg, plan: Plan) -> Doc {
  case a.label, a.value {
    Some(l), Some(v) -> doc.concat([t(l <> ": "), expr(v, plan)])
    Some(l), None -> t(l <> ": " <> l)
    None, Some(v) -> expr(v, plan)
    None, None -> doc.empty
  }
  |> mk(a.span)
}

fn string_doc(parts: List(ast.StringPart), plan: Plan) -> Doc {
  let pieces =
    list.map(parts, fn(p) {
      case p {
        // Only the content is marked: it is identical in both languages.
        ast.Text(raw, s) ->
          doc.concat([
            t("\""),
            t(lexer.to_gleam_string_content(raw)) |> mk(s),
            t("\""),
          ])
        // `<>` has precedence 5 (and is associative); anything looser must
        // be wrapped.
        ast.Interpolation(x, _) -> operand(x, 5, plan)
      }
    })
  case pieces, parts {
    [], _ -> t("\"\"")
    [single], [ast.Interpolation(..)] -> doc.concat([t("\"\" <> "), single])
    [single], _ -> single
    _, _ -> doc.join(pieces, t(" <> "))
  }
}

fn case_doc(subjects: List(Doc), clauses: List(Doc)) -> Doc {
  doc.concat([
    t("case "),
    doc.join(subjects, t(", ")),
    t(" {"),
    doc.nest(
      doc.concat(list.map(clauses, fn(c) { doc.concat([doc.hard_line, c]) })),
      2,
    ),
    doc.hard_line,
    t("}"),
  ])
}

fn case_clause(c: ast.CaseClause, plan: Plan) -> Doc {
  let alternatives =
    list.map(c.alternatives, fn(alt) {
      doc.join(list.map(alt, pattern(_, plan)), t(", "))
    })
  doc.concat([
    doc.join(alternatives, t(" | ")),
    case c.guard {
      Some(g) -> doc.concat([t(" if "), expr(g, plan)])
      None -> doc.empty
    },
    t(" ->"),
    case c.body {
      ast.Block(_, [ast.Expression(e)]) -> arm_body(e, plan)
      ast.Block(_, stmts) -> doc.concat([t(" "), block(stmts, plan)])
      body -> arm_body(body, plan)
    },
  ])
  |> mk(c.span)
}

/// The body of a case arm goes on the same line if it fits, otherwise on the
/// next line, indented (blocks always stay on the same line).
fn arm_body(e: Expr, plan: Plan) -> Doc {
  case e {
    ast.Block(..) | ast.Fn(..) -> doc.concat([t(" "), expr(e, plan)])
    // Multi-line constructs always go on their own line, like gleam format.
    ast.Case(..) | ast.If(..) ->
      doc.nest(doc.concat([doc.hard_line, expr(e, plan)]), 2)
    _ -> doc.group(doc.nest(doc.concat([doc.line, expr(e, plan)]), 2))
  }
}

/// A case/if branch body: a lone expression stays inline, anything else
/// becomes a block.
fn branch(stmts: List(Statement), plan: Plan) -> Doc {
  case stmts {
    [ast.Expression(e)] -> arm_body(e, plan)
    _ -> doc.concat([t(" "), block(stmts, plan)])
  }
}

fn segment(seg: ast.Segment(v), value: fn(v) -> Doc) -> Doc {
  let opts = case seg.options {
    [] -> doc.empty
    opts ->
      doc.concat([
        t(":"),
        doc.join(
          list.map(opts, fn(o) {
            case o.arg {
              Some(a) -> doc.concat([t(o.name <> "("), value(a), t(")")])
              None -> t(o.name)
            }
          }),
          t("-"),
        ),
      ])
  }
  doc.concat([value(seg.value), opts]) |> mk(seg.span)
}

// --- Patterns -------------------------------------------------------------------------

fn pattern(p: Pattern, plan: Plan) -> Doc {
  pattern_inner(p, plan) |> mk(p.span)
}

fn pattern_inner(p: Pattern, plan: Plan) -> Doc {
  case p {
    ast.PInt(_, text) | ast.PFloat(_, text) -> t(text)
    ast.PString(_, raw) -> t("\"" <> lexer.to_gleam_string_content(raw) <> "\"")
    ast.PVar(_, n) | ast.PDiscard(_, n) -> t(n)
    ast.PTuple(_, ps) ->
      doc.comma_list("#(", list.map(ps, pattern(_, plan)), ")")
    ast.PList(_, ps, tail) -> {
      let tail = case tail {
        Some(ast.PDiscard(_, "_")) -> [t("..")]
        Some(tl) -> [doc.concat([t(".."), pattern(tl, plan)])]
        None -> []
      }
      doc.comma_list(
        "[",
        list.append(list.map(ps, pattern(_, plan)), tail),
        "]",
      )
    }
    ast.PConstructor(_, m, name, args, spread) -> {
      let n = case m {
        Some(m) -> m <> "." <> name
        None -> name
      }
      let args =
        list.map(args, fn(a) {
          case a.label, a.value {
            Some(l), Some(v) -> doc.concat([t(l <> ": "), pattern(v, plan)])
            Some(l), None -> t(l <> ": " <> l)
            None, Some(v) -> pattern(v, plan)
            None, None -> doc.empty
          }
          |> mk(a.span)
        })
      let args = case spread {
        True -> list.append(args, [t("..")])
        False -> args
      }
      case args {
        [] -> t(n)
        _ -> doc.concat([t(n), doc.comma_list("(", args, ")")])
      }
    }
    ast.PAssign(_, inner, name) ->
      doc.concat([pattern(inner, plan), t(" as " <> name)])
    ast.PConcat(_, prefix, name, rest) ->
      doc.concat([
        t("\"" <> lexer.to_gleam_string_content(prefix) <> "\""),
        case name {
          Some(n) -> t(" as " <> n)
          None -> doc.empty
        },
        t(" <> "),
        pattern(rest, plan),
      ])
    ast.PBitArray(_, segs) ->
      doc.comma_list("<<", list.map(segs, segment(_, pattern(_, plan))), ">>")
  }
}

fn pipe_chain(e: Expr, acc: List(Expr)) -> #(Expr, List(Expr)) {
  case e {
    ast.BinaryOp(_, ast.Pipe, l, r) -> pipe_chain(l, [r, ..acc])
    _ -> #(e, acc)
  }
}

fn flat_list(open: String, docs: List(Doc), close: String) -> Doc {
  doc.concat([t(open), doc.join(docs, t(", ")), t(close)])
}

/// Right hand side of `let x =`: bracketed things hug the `=`, operator
/// chains move to the next line when they don't fit.
fn assigned(e: Expr, plan: Plan) -> Doc {
  case e {
    ast.BinaryOp(..) ->
      doc.group(doc.nest(doc.concat([doc.line, expr(e, plan)]), 2))
    _ -> doc.concat([t(" "), expr(e, plan)])
  }
}

/// `One(x) = One(4)` can't fail even if `One`'s type has other variants.
fn same_constructor(p: Pattern, value: Expr) -> Bool {
  let name = case value {
    ast.Call(_, ast.Constructor(_, m, n), _) | ast.Constructor(_, m, n) ->
      Some(#(m, n))
    _ -> None
  }
  case p, name {
    ast.PConstructor(_, pm, pn, args, _), Some(#(m, n)) ->
      pm == m
      && pn == n
      && list.all(args, fn(a) {
        case a.value {
          None -> True
          Some(ast.PVar(..)) | Some(ast.PDiscard(..)) -> True
          Some(_) -> False
        }
      })
    _, _ -> False
  }
}
