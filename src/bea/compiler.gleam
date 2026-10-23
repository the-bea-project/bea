//// Compiles one Bea module to Gleam.

import bea/ast
import bea/codegen
import bea/deriving
import bea/diagnostic.{type Diagnostic}
import bea/doc
import bea/lower
import bea/parser
import gleam/list

pub type Compiled {
  Compiled(
    gleam: String,
    mappings: List(doc.Mapping),
    warnings: List(Diagnostic),
    module: ast.Module,
  )
}

pub fn parse(source: String) -> Result(ast.Module, List(Diagnostic)) {
  let parsed = parser.parse_module(source)
  case parsed.errors {
    [] -> Ok(parsed.module)
    errors -> Error(errors)
  }
}

pub fn compile(
  source: String,
  ctx: codegen.Context,
) -> Result(Compiled, List(Diagnostic)) {
  case parse(source) {
    Error(errors) -> Error(errors)
    Ok(module) -> compile_module(module, ctx)
  }
}

pub fn compile_module(
  module: ast.Module,
  ctx: codegen.Context,
) -> Result(Compiled, List(Diagnostic)) {
  let #(derived, derive_errors) = deriving.module(module, ctx)
  let #(lowered, diagnostics) = lower.module(derived)
  let diagnostics = list.append(derive_errors, diagnostics)
  let #(errors, warnings) = list.partition(diagnostics, diagnostic.is_error)
  case errors {
    [_, ..] -> Error(errors)
    [] -> {
      let out = codegen.generate(lowered, ctx)
      Ok(Compiled(out.code, out.mappings, warnings, module))
    }
  }
}
