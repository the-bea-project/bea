//// Bea projects and the generated Gleam project behind them.
////
//// A Bea project is a directory with a `bea.toml` (same format as
//// `gleam.toml`) and a `src/` directory. Bea mirrors it into `.beabuild/`:
////
//// - `bea.toml` becomes `.beabuild/gleam.toml`
//// - `manifest.toml` is kept in sync in both directions (the root copy is
////   the lock file you commit)
//// - every `src/**/*.bea` is compiled to `.beabuild/src/**/*.gleam`
//// - every other source file Gleam understands (`.gleam`, `.erl`, `.hrl`,
////   `.mjs`, `.js`, `.ts`, ...) is copied unchanged, so Bea and Gleam
////   modules (and FFI files) can live side by side and import each other.
////   That includes code that tools generate in `src/` (such as Marmot's
////   `src/generated/sql/`): it stays where the tool wrote it, Bea only ever
////   writes to `.beabuild/`, and a copy is refreshed or removed whenever
////   its source changes or goes away, so the build never uses stale code.
////
//// Files are only rewritten when their content changes, which keeps Gleam's
//// incremental compilation effective.
////
//// Running `bea run some/file.bea` outside a project uses "script mode": the
//// file's directory acts as `src/`, with a default configuration.

import bea/ast
import bea/codegen
import bea/compiler
import bea/deriving
import bea/diagnostic.{type Diagnostic}
import bea/sourcemap.{type SourceMap}
import bea/span
import bea/system
import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import simplifile

pub type Project {
  Project(
    /// Absolute path of the directory holding `bea.toml`.
    root: String,
    /// Absolute path of the source directory.
    src_dir: String,
    /// Absolute path of the generated Gleam project.
    build_dir: String,
    name: String,
    /// True for script mode (no `bea.toml`).
    script: Bool,
    config: String,
  )
}

pub const config_file = "bea.toml"

pub const build_dir_name = ".beabuild"

pub fn default_config(name: String) -> String {
  "name = \""
  <> name
  <> "\"\nversion = \"1.0.0\"\n\n[dependencies]\ngleam_stdlib = \">= 0.44.0 and < 2.0.0\"\n"
}

/// Find the project containing `dir` by looking for `bea.toml` upwards.
pub fn find(dir: String) -> Result(Project, Nil) {
  let dir = system.absolute_path(dir)
  case simplifile.read(dir <> "/" <> config_file) {
    Ok(config) ->
      Ok(Project(
        root: dir,
        src_dir: dir <> "/src",
        build_dir: dir <> "/" <> build_dir_name,
        name: package_name(config) |> result.unwrap("bea_app"),
        script: False,
        config: config,
      ))
    Error(_) ->
      case parent(dir) {
        Ok(p) -> find(p)
        Error(_) -> Error(Nil)
      }
  }
}

fn parent(dir: String) -> Result(String, Nil) {
  case string.split(dir, "/") |> list.reverse {
    [_, ..rest] if rest != [] && rest != [""] ->
      Ok(rest |> list.reverse |> string.join("/"))
    _ -> Error(Nil)
  }
}

/// A project for a loose `.bea` file outside of any project.
pub fn script(file: String) -> Project {
  let file = system.absolute_path(file)
  let dir = parent(file) |> result.unwrap(".")
  Project(
    root: dir,
    src_dir: dir,
    build_dir: dir <> "/" <> build_dir_name,
    name: "bea_script",
    script: True,
    config: default_config("bea_script"),
  )
}

/// Reads the top level `name = "..."` from a TOML config.
pub fn package_name(config: String) -> Result(String, Nil) {
  config
  |> string.split("\n")
  |> list.take_while(fn(l) { !string.starts_with(string.trim(l), "[") })
  |> list.find_map(fn(line) {
    case string.split_once(string.trim(line), "=") {
      Ok(#(key, value)) ->
        case string.trim(key) {
          "name" ->
            value
            |> string.trim
            |> string.replace("\"", "")
            |> string.replace("'", "")
            |> Ok
          _ -> Error(Nil)
        }
      Error(_) -> Error(Nil)
    }
  })
}

// --- Modules -----------------------------------------------------------------

pub type Module {
  Module(
    /// Gleam module name, e.g. `app/util`.
    name: String,
    /// Absolute path of the `.bea` file.
    bea_path: String,
    /// Absolute path of the generated `.gleam` file.
    gleam_path: String,
    source: String,
    map: SourceMap,
  )
}

pub type FileErrors {
  FileErrors(path: String, source: String, diagnostics: List(Diagnostic))
}

pub type Sync {
  Sync(
    /// Compiled Bea modules keyed by the absolute path of their Gleam file.
    modules: Dict(String, Module),
    errors: List(FileErrors),
    warnings: List(FileErrors),
    /// Files in the build directory whose content changed in this sync.
    written: List(String),
    /// What code generation knew about the project's modules (the language
    /// server compiles edited copies of a module with it).
    context: codegen.Context,
  )
}

/// Extensions copied verbatim into the Gleam project.
const passthrough = [
  ".gleam", ".erl", ".hrl", ".ex", ".mjs", ".js", ".cjs", ".ts", ".mts", ".d.ts",
  ".d.mts",
]

fn is_passthrough(path: String) -> Bool {
  list.any(passthrough, fn(ext) { string.ends_with(path, ext) })
}

/// Write a file only if its content changed. Returns whether it was written.
pub fn write_if_changed(path: String, content: String) -> Bool {
  case simplifile.read(path) {
    Ok(existing) if existing == content -> False
    _ -> {
      let _ = simplifile.create_directory_all(dirname(path))
      let _ = simplifile.write(path, content)
      True
    }
  }
}

pub fn dirname(path: String) -> String {
  parent(path) |> result.unwrap(".")
}

/// Mirror configuration into the build directory (and manifest both ways).
pub fn sync_config(project: Project) -> Nil {
  let _ = simplifile.create_directory_all(project.build_dir <> "/src")
  write_if_changed(project.build_dir <> "/gleam.toml", project.config)
  case project.script {
    True -> Nil
    False -> {
      let root_manifest = project.root <> "/manifest.toml"
      let build_manifest = project.build_dir <> "/manifest.toml"
      case simplifile.read(root_manifest) {
        Ok(m) -> {
          write_if_changed(build_manifest, m)
          Nil
        }
        Error(_) -> Nil
      }
    }
  }
}

/// Copy files Gleam may have changed (`gleam add` & co) back to the project.
pub fn sync_back(project: Project, include_config: Bool) -> Nil {
  case project.script {
    True -> Nil
    False -> {
      case simplifile.read(project.build_dir <> "/manifest.toml") {
        Ok(m) -> {
          write_if_changed(project.root <> "/manifest.toml", m)
          Nil
        }
        Error(_) -> Nil
      }
      case include_config {
        True ->
          case simplifile.read(project.build_dir <> "/gleam.toml") {
            Ok(c) -> {
              write_if_changed(project.root <> "/" <> config_file, c)
              Nil
            }
            Error(_) -> Nil
          }
        False -> Nil
      }
    }
  }
}

/// Recursively list source files, skipping hidden and build directories.
pub fn source_files(dir: String) -> List(String) {
  case simplifile.read_directory(dir) {
    Error(_) -> []
    Ok(entries) ->
      entries
      |> list.sort(string.compare)
      |> list.flat_map(fn(entry) {
        let path = dir <> "/" <> entry
        case string.starts_with(entry, "."), simplifile.is_directory(path) {
          True, _ -> []
          False, Ok(True) ->
            case entry == "build" || entry == "node_modules" {
              True -> []
              False -> source_files(path)
            }
          False, _ -> [path]
        }
      })
  }
}

pub fn module_name(project: Project, path: String) -> String {
  path
  |> string.drop_start(string.length(project.src_dir) + 1)
  |> strip_extension
}

fn strip_extension(path: String) -> String {
  case string.ends_with(path, ".bea") {
    True -> string.drop_end(path, 4)
    False -> path
  }
}

/// Is `name` a valid Gleam module path (`app/util`)?
pub fn valid_module_name(name: String) -> Bool {
  string.split(name, "/")
  |> list.all(fn(segment) {
    case string.to_graphemes(segment) {
      [first, ..rest] ->
        string.contains("abcdefghijklmnopqrstuvwxyz", first)
        && list.all(rest, fn(c) {
          string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", c)
        })
      [] -> False
    }
  })
}

/// Compile every Bea module (overriding file contents with `overrides`,
/// used by the language server for unsaved editor buffers) and mirror all
/// sources into the build directory.
pub fn sync(project: Project, overrides: Dict(String, String)) -> Sync {
  sync_cached(project, overrides, new_cache()).0
}

/// Parse and compile results from a previous sync, reused when neither the
/// source nor the cross-module context changed (the language server syncs on
/// every edit).
pub opaque type Cache {
  Cache(
    entries: Dict(String, CacheEntry),
    /// Gleam modules of the project: source and single constructors.
    gleam: Dict(String, #(String, Set(String))),
  )
}

type CacheEntry {
  CacheEntry(
    source: String,
    parsed: Result(ast.Module, List(Diagnostic)),
    context_hash: Int,
    compiled: Option(Result(compiler.Compiled, List(Diagnostic))),
  )
}

pub fn new_cache() -> Cache {
  Cache(dict.new(), dict.new())
}

@external(erlang, "bea_ffi", "hash")
fn hash(term: a) -> Int

pub fn sync_cached(
  project: Project,
  overrides: Dict(String, String),
  cache: Cache,
) -> #(Sync, Cache) {
  sync_config(project)
  let files = source_files(project.src_dir)
  let #(bea_files, other_files) =
    list.partition(files, fn(f) { string.ends_with(f, ".bea") })
  let other_files = list.filter(other_files, is_passthrough)

  let read = fn(path) {
    case dict.get(overrides, path) {
      Ok(text) -> Ok(text)
      Error(_) -> simplifile.read(path) |> result.replace_error(Nil)
    }
  }

  // Gleam modules living in src/ (hand written, or generated by tools such
  // as Marmot) are compiled with the Bea modules; code generation needs to
  // know their single-constructor types like those of Bea modules.
  let gleam_modules =
    other_files
    |> list.filter(fn(f) { string.ends_with(f, ".gleam") })
    |> list.filter_map(fn(path) {
      use source <- result.map(read(path))
      let singles = case dict.get(cache.gleam, path) {
        Ok(#(cached, singles)) if cached == source -> singles
        _ -> codegen.gleam_single_constructors(source)
      }
      #(path, source, singles)
    })

  // Parse everything first so modules can learn about each other's types.
  let parsed =
    list.map(bea_files, fn(path) {
      let source = read(path) |> result.unwrap("")
      let name = module_name(project, path)
      let parsed = case dict.get(cache.entries, path) {
        Ok(entry) if entry.source == source -> entry.parsed
        _ -> compiler.parse(source)
      }
      #(path, name, source, parsed)
    })
  let gleam_singles =
    list.fold(gleam_modules, dict.new(), fn(acc, g) {
      case set.is_empty(g.2) {
        True -> acc
        False -> dict.insert(acc, gleam_module_name(project, g.0), g.2)
      }
    })
  let ctx =
    codegen.Context(
      single_constructors: list.fold(parsed, gleam_singles, fn(acc, p) {
        case p.3 {
          Ok(m) ->
            dict.insert(acc, p.1, codegen.exported_single_constructors(m))
          Error(_) -> acc
        }
      }),
      derived: list.fold(parsed, dict.new(), fn(acc, p) {
        case p.3 {
          Ok(m) -> dict.insert(acc, p.1, deriving.exports(m))
          Error(_) -> acc
        }
      }),
      aliases: list.fold(parsed, dict.new(), fn(acc, p) {
        case p.3 {
          Ok(m) -> dict.insert(acc, p.1, deriving.portable_aliases(m))
          Error(_) -> acc
        }
      }),
    )

  let gleam_names =
    other_files
    |> list.filter(fn(f) { string.ends_with(f, ".gleam") })
    |> list.map(gleam_module_name(project, _))
    |> set.from_list

  let context_hash = hash(ctx)
  let #(modules, errors, warnings, entries) =
    list.fold(parsed, #(dict.new(), [], [], dict.new()), fn(acc, p) {
      let #(modules, errors, warnings, entries) = acc
      let #(path, name, source, parsed) = p
      let gleam_path = project.build_dir <> "/src/" <> name <> ".gleam"
      let structural = case
        valid_module_name(name),
        set.contains(gleam_names, name)
      {
        False, _ ->
          Some(diagnostic.error(
            "Invalid module name",
            file_start(),
            "`"
              <> name
              <> "` is not a valid module name: use lowercase letters, digits and underscores",
          ))
        _, True ->
          Some(diagnostic.error(
            "Duplicate module",
            file_start(),
            "both `" <> name <> ".bea` and `" <> name <> ".gleam` exist",
          ))
        True, False -> None
      }
      let cached = case dict.get(cache.entries, path) {
        Ok(CacheEntry(source: s, context_hash: h, compiled: Some(c), ..))
          if s == source && h == context_hash
        -> Some(c)
        _ -> None
      }
      let result = case structural, parsed, cached {
        Some(d), _, _ -> Error([d])
        None, Error(e), _ -> Error(e)
        None, Ok(_), Some(c) -> c
        None, Ok(m), None -> compiler.compile_module(m, ctx)
      }
      let entries =
        dict.insert(
          entries,
          path,
          CacheEntry(source, parsed, context_hash, Some(result)),
        )
      case result {
        Error(diags) -> #(
          modules,
          [FileErrors(path, source, diags), ..errors],
          warnings,
          entries,
        )
        Ok(compiled) -> {
          let _ = write_if_changed(gleam_path, compiled.gleam)
          let module =
            Module(
              name: name,
              bea_path: path,
              gleam_path: gleam_path,
              source: source,
              map: sourcemap.new(compiled.mappings, source, compiled.gleam),
            )
          let warnings = case compiled.warnings {
            [] -> warnings
            ws -> [FileErrors(path, source, ws), ..warnings]
          }
          #(dict.insert(modules, gleam_path, module), errors, warnings, entries)
        }
      }
    })

  // Copy Gleam modules and FFI files across unchanged.
  let copies =
    list.map(other_files, fn(path) {
      let rel = string.drop_start(path, string.length(project.src_dir) + 1)
      let dest = project.build_dir <> "/src/" <> rel
      let changed = case read(path) {
        Ok(content) -> write_if_changed(dest, content)
        Error(_) -> {
          let _ = simplifile.copy_file(path, dest)
          True
        }
      }
      #(dest, changed)
    })
  let copied = list.map(copies, fn(c) { c.0 })
  let written_copies =
    list.filter_map(copies, fn(c) {
      case c.1 {
        True -> Ok(c.0)
        False -> Error(Nil)
      }
    })

  // Remove generated files whose source is gone. Modules that failed to
  // compile keep their previous output so editors keep working.
  let failed =
    list.map(errors, fn(e) {
      project.build_dir <> "/src/" <> module_name(project, e.path) <> ".gleam"
    })
  let keep = set.from_list(list.flatten([dict.keys(modules), copied, failed]))
  source_files(project.build_dir <> "/src")
  |> list.filter(fn(f) { is_passthrough(f) && !set.contains(keep, f) })
  |> list.each(fn(f) {
    let _ = simplifile.delete(f)
    Nil
  })

  #(
    Sync(
      modules,
      list.reverse(errors),
      list.reverse(warnings),
      written_copies,
      ctx,
    ),
    Cache(
      entries,
      list.map(gleam_modules, fn(g) { #(g.0, #(g.1, g.2)) }) |> dict.from_list,
    ),
  )
}

fn gleam_module_name(project: Project, path: String) -> String {
  string.drop_start(path, string.length(project.src_dir) + 1)
  |> string.drop_end(6)
}

/// Path in the build directory that a passthrough source file is copied to.
pub fn copied_path(project: Project, source: String) -> String {
  project.build_dir
  <> "/src/"
  <> string.drop_start(source, string.length(project.src_dir) + 1)
}

/// The original source of a copied passthrough file, if it is one.
pub fn original_path(project: Project, built: String) -> Option(String) {
  let prefix = project.build_dir <> "/src/"
  case string.starts_with(built, prefix) && !string.ends_with(built, ".bea") {
    True ->
      Some(
        project.src_dir
        <> "/"
        <> string.drop_start(built, string.length(prefix)),
      )
    False -> None
  }
}

/// Whole-file problems are reported at the start of the file.
fn file_start() -> span.Span {
  span.Span(0, 0)
}

/// Does a dependency directory exist yet (has `gleam deps download` run)?
pub fn has_deps(project: Project) -> Bool {
  simplifile.is_directory(project.build_dir <> "/build/packages")
  |> result.unwrap(False)
}

pub fn display_path(path: String) -> String {
  let cwd = system.cwd() <> "/"
  case string.starts_with(path, cwd) {
    True -> string.drop_start(path, string.length(cwd))
    False -> path
  }
}

pub fn modules_by_name(sync: Sync) -> Dict(String, Module) {
  sync.modules
  |> dict.values
  |> list.map(fn(m) { #(m.name, m) })
  |> dict.from_list
}

pub fn option_module(sync: Sync, gleam_path: String) -> Option(Module) {
  dict.get(sync.modules, gleam_path) |> option.from_result
}
