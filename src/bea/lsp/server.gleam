//// The Bea language server.
////
//// Bea compiles to Gleam, so rather than re-implementing type checking,
//// completion and navigation, this server runs `gleam lsp` on the generated
//// project (`.beabuild/`) and acts as a translating proxy:
////
//// ```text
////  editor ── .bea positions ──▶ bea lsp ── .gleam positions ──▶ gleam lsp
////         ◀─ .bea positions ───         ◀─ .gleam positions ──
//// ```
////
//// - Open `.bea` buffers are compiled on every change (debounced). The
////   generated Gleam is sent to `gleam lsp` as an open document, and the
////   source map from compilation translates positions both ways.
//// - Bea's own syntax errors are reported directly; Gleam's diagnostics are
////   translated back onto the `.bea` source.
//// - Formatting and document symbols are answered natively from the Bea
////   syntax tree.
//// - Completion while code doesn't parse (e.g. right after `list.`) is
////   handled by compiling a copy with a placeholder name at the cursor.
////
//// One `gleam lsp` child is started per Bea project (or per folder of loose
//// `.bea` files).

import bea/codegen
import bea/compiler
import bea/diagnostic.{type Diagnostic}
import bea/formatter
import bea/lsp/json.{type Json}
import bea/lsp/position
import bea/lsp/symbols
import bea/lsp/transport.{type Port}
import bea/parser
import bea/project.{type Project}
import bea/sourcemap.{type SourceMap}
import bea/span.{Span}
import bea/system
import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const placeholder = "bea_lsp_hole"

// --- State ----------------------------------------------------------------------

type Document {
  Document(path: String, text: String, version: Int)
}

type Child {
  Child(
    key: String,
    project: Project,
    port: Port,
    buffer: BitArray,
    ready: Bool,
    queue: List(Json),
    /// Generated documents opened in `gleam lsp`: path -> (version, text).
    open: Dict(String, #(Int, String)),
    /// Latest successfully compiled modules, by generated Gleam path.
    modules: Dict(String, project.Module),
    cache: project.Cache,
    dirty: Bool,
    /// Bea source paths that have Bea diagnostics published.
    errored: List(String),
  )
}

type Pending {
  Pending(
    child: String,
    method: String,
    /// Source path of the document the request was about.
    path: String,
    /// How to translate positions in the response for that document.
    map: Option(SourceMap),
    /// Offset of the cursor in the Bea document (for completion).
    cursor: Int,
    /// Generated module to restore after a placeholder completion.
    restore: Option(String),
  )
}

type State {
  State(
    init_params: Json,
    children: Dict(String, Child),
    docs: Dict(String, Document),
    pending: Dict(String, Pending),
    /// Requests from children forwarded to the client: our id -> (child, id).
    forwarded: Dict(String, #(String, Json)),
    next_id: Int,
    bea_diagnostics: Dict(String, List(Json)),
    gleam_diagnostics: Dict(String, List(Json)),
    shutting_down: Bool,
    verbose: Bool,
  )
}

pub fn main() -> Int {
  transport.start()
  let verbose = result.is_ok(system.get_env("BEA_LSP_LOG"))
  let state =
    State(
      init_params: json.Null,
      children: dict.new(),
      docs: dict.new(),
      pending: dict.new(),
      forwarded: dict.new(),
      next_id: 1,
      bea_diagnostics: dict.new(),
      gleam_diagnostics: dict.new(),
      shutting_down: False,
      verbose: verbose,
    )
  loop(state)
}

fn loop(state: State) -> Int {
  let dirty = dict.values(state.children) |> list.any(fn(c) { c.dirty })
  let timeout = case dirty {
    True -> 40
    False -> -1
  }
  case transport.receive(timeout) {
    transport.ClientMessage(body) ->
      case json.parse_bits(body) {
        Ok(message) ->
          case handle_client(state, message) {
            Ok(state) -> loop(state)
            Error(code) -> stop(state, code)
          }
        Error(_) -> {
          transport.log("could not parse client message")
          loop(state)
        }
      }
    transport.ClientClosed -> stop(state, 0)
    transport.ServerData(port, data) -> loop(child_data(state, port, data))
    transport.ServerExit(port, code) -> loop(child_exit(state, port, code))
    transport.Timeout -> loop(refresh_dirty(state))
  }
}

fn stop(state: State, code: Int) -> Int {
  dict.values(state.children)
  |> list.each(fn(c) {
    transport.send_child(
      c.port,
      json.object([
        #("jsonrpc", json.String("2.0")),
        #("method", json.String("exit")),
        #("params", json.Null),
      ]),
    )
  })
  // Give the children a moment to exit cleanly before closing the pipes.
  wait_for_exits(dict.size(state.children), system.monotonic_ms() + 2000)
  dict.values(state.children) |> list.each(fn(c) { transport.close(c.port) })
  code
}

fn wait_for_exits(remaining: Int, deadline: Int) -> Nil {
  let left = deadline - system.monotonic_ms()
  case remaining <= 0 || left <= 0 {
    True -> Nil
    False ->
      case transport.receive(left) {
        transport.ServerExit(..) -> wait_for_exits(remaining - 1, deadline)
        transport.Timeout -> Nil
        _ -> wait_for_exits(remaining, deadline)
      }
  }
}

fn log(state: State, message: String) -> Nil {
  case state.verbose {
    True -> transport.log(message)
    False -> Nil
  }
}

// --- Client messages ------------------------------------------------------------

fn id_key(id: Json) -> String {
  case id {
    json.Int(i) -> "i:" <> int.to_string(i)
    json.String(s) -> "s:" <> s
    other -> "j:" <> json.to_string(other)
  }
}

fn respond(id: Json, result: Json) -> Nil {
  transport.send_client(
    json.object([
      #("jsonrpc", json.String("2.0")),
      #("id", id),
      #("result", result),
    ]),
  )
}

fn respond_error(id: Json, code: Int, message: String) -> Nil {
  transport.send_client(
    json.object([
      #("jsonrpc", json.String("2.0")),
      #("id", id),
      #(
        "error",
        json.object([
          #("code", json.Int(code)),
          #("message", json.String(message)),
        ]),
      ),
    ]),
  )
}

fn notify_client(method: String, params: Json) -> Nil {
  transport.send_client(
    json.object([
      #("jsonrpc", json.String("2.0")),
      #("method", json.String(method)),
      #("params", params),
    ]),
  )
}

fn show_message(kind: Int, message: String) -> Nil {
  notify_client(
    "window/showMessage",
    json.object([#("type", json.Int(kind)), #("message", json.String(message))]),
  )
}

fn handle_client(state: State, message: Json) -> Result(State, Int) {
  let params = json.get(message, "params") |> option.unwrap(json.Null)
  case json.string_at(message, ["method"]), json.get(message, "id") {
    Some(method), Some(id) -> Ok(request(state, id, method, params))
    Some(method), None -> notification(state, method, params)
    None, Some(id) -> Ok(client_response(state, id, message))
    None, None -> Ok(state)
  }
}

fn capabilities() -> Json {
  json.object([
    #(
      "textDocumentSync",
      json.object([
        #("openClose", json.Bool(True)),
        #("change", json.Int(1)),
        #("save", json.object([#("includeText", json.Bool(False))])),
      ]),
    ),
    #("hoverProvider", json.Bool(True)),
    #("definitionProvider", json.Bool(True)),
    #("typeDefinitionProvider", json.Bool(True)),
    #("referencesProvider", json.Bool(True)),
    #("documentHighlightProvider", json.Bool(True)),
    #("documentFormattingProvider", json.Bool(True)),
    #("documentSymbolProvider", json.Bool(True)),
    #(
      "completionProvider",
      json.object([
        #("triggerCharacters", json.Array([json.String(".")])),
        #("resolveProvider", json.Bool(False)),
      ]),
    ),
    #(
      "signatureHelpProvider",
      json.object([
        #(
          "triggerCharacters",
          json.Array([json.String("("), json.String(","), json.String(":")]),
        ),
      ]),
    ),
    #("renameProvider", json.object([#("prepareProvider", json.Bool(True))])),
  ])
}

fn request(state: State, id: Json, method: String, params: Json) -> State {
  case method {
    "initialize" -> {
      respond(
        id,
        json.object([
          #("capabilities", capabilities()),
          #(
            "serverInfo",
            json.object([
              #("name", json.String("bea")),
              #("version", json.String("0.2.0")),
            ]),
          ),
        ]),
      )
      let state = State(..state, init_params: params)
      // Start Gleam early for the workspace project so the first request
      // doesn't have to wait for it.
      case root_path(params) {
        Some(root) ->
          case project.find(root) {
            Ok(p) -> ensure_child(state, p).0
            Error(_) -> state
          }
        None -> state
      }
    }
    "shutdown" -> {
      dict.values(state.children)
      |> list.each(fn(c) {
        transport.send_child(
          c.port,
          json.object([
            #("jsonrpc", json.String("2.0")),
            #("id", json.String("bea-shutdown")),
            #("method", json.String("shutdown")),
            #("params", json.Null),
          ]),
        )
      })
      respond(id, json.Null)
      State(..state, shutting_down: True)
    }
    "textDocument/formatting" -> {
      format(state, id, params)
      state
    }
    "textDocument/documentSymbol" -> {
      document_symbols(state, id, params)
      state
    }
    "textDocument/hover"
    | "textDocument/definition"
    | "textDocument/typeDefinition"
    | "textDocument/references"
    | "textDocument/documentHighlight"
    | "textDocument/signatureHelp"
    | "textDocument/completion"
    | "textDocument/prepareRename"
    | "textDocument/rename" -> positional(state, id, method, params)
    _ -> {
      respond_error(id, -32_601, "Method not supported by bea: " <> method)
      state
    }
  }
}

fn root_path(params: Json) -> Option(String) {
  let from_uri = case json.string_at(params, ["rootUri"]) {
    Some(u) -> position.uri_to_path(u)
    None -> None
  }
  case from_uri {
    Some(p) -> Some(p)
    None ->
      case json.at(params, ["workspaceFolders"]) {
        Some(json.Array([first, ..])) ->
          json.string_at(first, ["uri"]) |> option.then(position.uri_to_path)
        _ -> json.string_at(params, ["rootPath"])
      }
  }
}

fn notification(
  state: State,
  method: String,
  params: Json,
) -> Result(State, Int) {
  case method {
    "exit" ->
      case state.shutting_down {
        True -> Error(0)
        False -> Error(1)
      }
    "textDocument/didOpen" -> {
      let uri =
        json.string_at(params, ["textDocument", "uri"]) |> option.unwrap("")
      let text =
        json.string_at(params, ["textDocument", "text"]) |> option.unwrap("")
      let version =
        json.int_at(params, ["textDocument", "version"]) |> option.unwrap(0)
      case position.uri_to_path(uri) {
        Some(path) -> {
          let state =
            State(
              ..state,
              docs: dict.insert(state.docs, path, Document(path, text, version)),
            )
          let #(state, key) = ensure_child(state, project_for(path))
          Ok(refresh(state, key))
        }
        None -> Ok(state)
      }
    }
    "textDocument/didChange" -> {
      let uri =
        json.string_at(params, ["textDocument", "uri"]) |> option.unwrap("")
      let version =
        json.int_at(params, ["textDocument", "version"]) |> option.unwrap(0)
      let text = case json.get(params, "contentChanges") {
        Some(json.Array(changes)) ->
          changes
          |> list.filter_map(fn(c) {
            option.to_result(json.string_at(c, ["text"]), Nil)
          })
          |> list.last
          |> option.from_result
        _ -> None
      }
      case position.uri_to_path(uri), text {
        Some(path), Some(text) -> {
          let state =
            State(
              ..state,
              docs: dict.insert(state.docs, path, Document(path, text, version)),
            )
          Ok(mark_dirty(state, path))
        }
        _, _ -> Ok(state)
      }
    }
    "textDocument/didSave" -> {
      let uri =
        json.string_at(params, ["textDocument", "uri"]) |> option.unwrap("")
      case position.uri_to_path(uri) {
        Some(path) -> {
          let #(state, key) = ensure_child(state, project_for(path))
          let state = refresh(state, key)
          // Let Gleam re-read the generated file it now finds on disk.
          case dict.get(state.children, key) {
            Ok(child) -> {
              let gleam_path = generated_path(child, path)
              case dict.has_key(child.open, gleam_path) {
                True -> {
                  let child =
                    send(
                      child,
                      "textDocument/didSave",
                      json.object([
                        #(
                          "textDocument",
                          json.object([
                            #(
                              "uri",
                              json.String(position.path_to_uri(gleam_path)),
                            ),
                          ]),
                        ),
                      ]),
                    )
                  Ok(put_child(state, child))
                }
                False -> Ok(state)
              }
            }
            Error(_) -> Ok(state)
          }
        }
        None -> Ok(state)
      }
    }
    "textDocument/didClose" -> {
      let uri =
        json.string_at(params, ["textDocument", "uri"]) |> option.unwrap("")
      case position.uri_to_path(uri) {
        Some(path) -> {
          let state = State(..state, docs: dict.delete(state.docs, path))
          let key = project_for(path).build_dir
          case dict.get(state.children, key) {
            Ok(child) -> {
              let gleam_path = generated_path(child, path)
              let child = case dict.has_key(child.open, gleam_path) {
                True ->
                  Child(
                    ..send(
                      child,
                      "textDocument/didClose",
                      json.object([
                        #(
                          "textDocument",
                          json.object([
                            #(
                              "uri",
                              json.String(position.path_to_uri(gleam_path)),
                            ),
                          ]),
                        ),
                      ]),
                    ),
                    open: dict.delete(child.open, gleam_path),
                  )
                False -> child
              }
              Ok(refresh(put_child(state, child), key))
            }
            Error(_) -> Ok(state)
          }
        }
        None -> Ok(state)
      }
    }
    "workspace/didChangeWatchedFiles" -> {
      let paths = case json.get(params, "changes") {
        Some(json.Array(changes)) ->
          list.filter_map(changes, fn(c) {
            json.string_at(c, ["uri"])
            |> option.then(position.uri_to_path)
            |> option.to_result(Nil)
          })
        _ -> []
      }
      Ok(
        list.fold(paths, state, fn(state, path) {
          case string.ends_with(path, project.config_file) {
            True -> reload_config(state, path)
            False -> mark_dirty(state, path)
          }
        }),
      )
    }
    "workspace/didChangeConfiguration" -> {
      Ok(broadcast(state, method, params))
    }
    "$/cancelRequest" -> {
      case json.get(params, "id") {
        Some(id) ->
          case dict.get(state.pending, id_key(id)) {
            Ok(p) ->
              case dict.get(state.children, p.child) {
                Ok(child) -> Ok(put_child(state, send(child, method, params)))
                Error(_) -> Ok(state)
              }
            Error(_) -> Ok(state)
          }
        None -> Ok(state)
      }
    }
    _ -> Ok(state)
  }
}

fn broadcast(state: State, method: String, params: Json) -> State {
  dict.fold(state.children, state, fn(state, _, child) {
    put_child(state, send(child, method, params))
  })
}

/// A response to a request that a child sent to the client.
fn client_response(state: State, id: Json, message: Json) -> State {
  case dict.get(state.forwarded, id_key(id)) {
    Ok(#(child_key, original)) ->
      case dict.get(state.children, child_key) {
        Ok(child) -> {
          let message = json.set(message, "id", original)
          transport.send_child(child.port, message)
          State(..state, forwarded: dict.delete(state.forwarded, id_key(id)))
        }
        Error(_) -> state
      }
    Error(_) -> state
  }
}

// --- Children ---------------------------------------------------------------------

fn project_for(path: String) -> Project {
  case project.find(project.dirname(path)) {
    Ok(p) -> p
    Error(_) -> project.script(path)
  }
}

fn put_child(state: State, child: Child) -> State {
  State(..state, children: dict.insert(state.children, child.key, child))
}

fn ensure_child(state: State, p: Project) -> #(State, String) {
  case dict.get(state.children, p.build_dir) {
    Ok(_) -> #(state, p.build_dir)
    Error(_) ->
      case system.gleam_executable() {
        Error(message) -> {
          show_message(1, message)
          #(state, p.build_dir)
        }
        Ok(gleam) -> {
          log(state, "starting gleam lsp for " <> p.build_dir)
          let #(sync, cache) =
            project.sync_cached(p, overrides(state, p), project.new_cache())
          case project.has_deps(p) {
            True -> Nil
            False -> {
              let _ =
                system.run_lines(
                  gleam,
                  ["deps", "download"],
                  p.build_dir,
                  Nil,
                  fn(_, line) { transport.log(line) },
                )
              Nil
            }
          }
          let port = transport.spawn(gleam, ["lsp"], p.build_dir)
          let root = position.path_to_uri(p.build_dir)
          let params =
            state.init_params
            |> json.set("rootUri", json.String(root))
            |> json.set("rootPath", json.String(p.build_dir))
            |> json.set(
              "workspaceFolders",
              json.Array([
                json.object([
                  #("uri", json.String(root)),
                  #("name", json.String(p.name)),
                ]),
              ]),
            )
            |> json.set("initializationOptions", json.Null)
          let params = case params {
            json.Null ->
              json.object([
                #("processId", json.Null),
                #("rootUri", json.String(root)),
                #("capabilities", json.object([])),
              ])
            _ -> params
          }
          transport.send_child(
            port,
            json.object([
              #("jsonrpc", json.String("2.0")),
              #("id", json.String("bea-init")),
              #("method", json.String("initialize")),
              #("params", params),
            ]),
          )
          let child =
            Child(
              key: p.build_dir,
              project: p,
              port: port,
              buffer: <<>>,
              ready: False,
              queue: [],
              open: dict.new(),
              modules: sync.modules,
              cache: cache,
              dirty: False,
              errored: [],
            )
          #(put_child(state, child), p.build_dir)
        }
      }
  }
}

fn reload_config(state: State, config_path: String) -> State {
  let root = project.dirname(config_path)
  case
    dict.get(state.children, root <> "/" <> project.build_dir_name),
    project.find(root)
  {
    Ok(child), Ok(p) -> {
      let child = Child(..child, project: p, dirty: True)
      let state = put_child(state, child)
      let gleam_toml = position.path_to_uri(p.build_dir <> "/gleam.toml")
      project.sync_config(p)
      put_child(
        state,
        send(
          child,
          "workspace/didChangeWatchedFiles",
          json.object([
            #(
              "changes",
              json.Array([
                json.object([
                  #("uri", json.String(gleam_toml)),
                  #("type", json.Int(2)),
                ]),
              ]),
            ),
          ]),
        ),
      )
    }
    _, _ -> state
  }
}

/// Send (or queue, until the child has initialised) a notification.
fn send(child: Child, method: String, params: Json) -> Child {
  let message =
    json.object([
      #("jsonrpc", json.String("2.0")),
      #("method", json.String(method)),
      #("params", params),
    ])
  send_message(child, message)
}

fn send_message(child: Child, message: Json) -> Child {
  case child.ready {
    True -> {
      transport.send_child(child.port, message)
      child
    }
    False -> Child(..child, queue: [message, ..child.queue])
  }
}

fn child_by_port(state: State, port: Port) -> Option(Child) {
  dict.values(state.children)
  |> list.find(fn(c) { system_same(c.port, port) })
  |> option.from_result
}

@external(erlang, "erlang", "=:=")
fn system_same(a: Port, b: Port) -> Bool

fn child_exit(state: State, port: Port, code: Int) -> State {
  case child_by_port(state, port) {
    Some(child) -> {
      case state.shutting_down {
        True -> Nil
        False ->
          show_message(
            1,
            "gleam lsp exited with code "
              <> int.to_string(code)
              <> "; it will be restarted when you next edit a file.",
          )
      }
      State(..state, children: dict.delete(state.children, child.key))
    }
    None -> state
  }
}

fn child_data(state: State, port: Port, data: BitArray) -> State {
  case child_by_port(state, port) {
    None -> state
    Some(child) -> {
      let #(bodies, rest) =
        transport.split_frames(bit_array.append(child.buffer, data))
      let state = put_child(state, Child(..child, buffer: rest))
      list.fold(bodies, state, fn(state, body) {
        case json.parse_bits(body) {
          Ok(message) -> child_message(state, child.key, message)
          Error(_) -> state
        }
      })
    }
  }
}

fn child_message(state: State, key: String, message: Json) -> State {
  let assert Ok(child) = dict.get(state.children, key)
  case json.string_at(message, ["method"]), json.get(message, "id") {
    // A response to one of our requests.
    None, Some(json.String("bea-init")) -> {
      transport.send_child(
        child.port,
        json.object([
          #("jsonrpc", json.String("2.0")),
          #("method", json.String("initialized")),
          #("params", json.object([])),
        ]),
      )
      list.reverse(child.queue)
      |> list.each(fn(m) { transport.send_child(child.port, m) })
      put_child(state, Child(..child, ready: True, queue: []))
    }
    None, Some(json.String("bea-shutdown")) -> state
    None, Some(json.String("bea-restore-" <> _)) -> state
    None, Some(id) -> child_response(state, child, id, message)
    // A request from gleam to the editor.
    Some(_), Some(id) -> {
      let our_id = "bea-" <> int.to_string(state.next_id)
      transport.send_client(json.set(message, "id", json.String(our_id)))
      State(
        ..state,
        next_id: state.next_id + 1,
        forwarded: dict.insert(state.forwarded, "s:" <> our_id, #(key, id)),
      )
    }
    Some("textDocument/publishDiagnostics"), None ->
      gleam_diagnostics(
        state,
        child,
        json.get(message, "params") |> option.unwrap(json.Null),
      )
    Some(_), None -> {
      transport.send_client(message)
      state
    }
    None, None -> state
  }
}

// --- Compilation ------------------------------------------------------------------

fn overrides(state: State, p: Project) -> Dict(String, String) {
  state.docs
  |> dict.filter(fn(path, _) { string.starts_with(path, p.src_dir <> "/") })
  |> dict.map_values(fn(_, d) { d.text })
}

fn mark_dirty(state: State, path: String) -> State {
  let key = project_for(path).build_dir
  case dict.get(state.children, key) {
    Ok(child) -> put_child(state, Child(..child, dirty: True))
    Error(_) -> state
  }
}

fn refresh_dirty(state: State) -> State {
  dict.fold(state.children, state, fn(state, key, child) {
    case child.dirty {
      True -> refresh(state, key)
      False -> state
    }
  })
}

fn generated_path(child: Child, source: String) -> String {
  case string.ends_with(source, ".bea") {
    True ->
      child.project.build_dir
      <> "/src/"
      <> project.module_name(child.project, source)
      <> ".gleam"
    False -> project.copied_path(child.project, source)
  }
}

/// Recompile a project, publish Bea diagnostics, and bring `gleam lsp`'s view
/// of the generated code up to date.
fn refresh(state: State, key: String) -> State {
  case dict.get(state.children, key) {
    Error(_) -> state
    Ok(child) -> {
      let #(sync, cache) =
        project.sync_cached(
          child.project,
          overrides(state, child.project),
          child.cache,
        )
      let previous = child.modules
      let modules = dict.merge(child.modules, sync.modules)

      // Bea diagnostics.
      let by_file =
        list.fold(
          list.append(sync.errors, sync.warnings),
          dict.new(),
          fn(acc, f) {
            let index = span.line_index(f.source)
            let diags = list.map(f.diagnostics, bea_diagnostic(index, _))
            dict.upsert(acc, f.path, fn(existing) {
              list.append(option.unwrap(existing, []), diags)
            })
          },
        )
      let errored = dict.keys(by_file)
      let cleared =
        list.filter(child.errored, fn(p) { !list.contains(errored, p) })
      let bea_diagnostics =
        list.fold(cleared, state.bea_diagnostics, dict.delete)
        |> dict.merge(by_file)
      let state = State(..state, bea_diagnostics: bea_diagnostics)
      list.each(list.append(errored, cleared), publish(state, _))

      // Open documents: send the generated code to gleam.
      let child = Child(..child, modules:, cache:, dirty: False, errored:)
      let open_sources =
        dict.keys(state.docs)
        |> list.filter(fn(p) {
          string.starts_with(p, child.project.src_dir <> "/")
        })
      let child =
        list.fold(open_sources, child, fn(child, source) {
          let gleam_path = generated_path(child, source)
          let text = case string.ends_with(source, ".bea") {
            True ->
              dict.get(sync.modules, gleam_path)
              |> result.map(fn(m) { m.map.gleam_source })
            False ->
              dict.get(state.docs, source) |> result.map(fn(d) { d.text })
          }
          case text {
            Ok(text) -> sync_open(child, gleam_path, text)
            Error(_) -> child
          }
        })

      // Closed modules whose generated code changed on disk.
      let changed =
        dict.to_list(sync.modules)
        |> list.filter(fn(entry) {
          let #(path, m) = entry
          !dict.has_key(child.open, path)
          && case dict.get(previous, path) {
            Ok(old) -> old.map.gleam_source != m.map.gleam_source
            Error(_) -> True
          }
        })
        |> list.map(fn(entry) { entry.0 })
        // Hand written Gleam/FFI files copied from src/ that changed.
        |> list.append(
          list.filter(sync.written, fn(p) { !dict.has_key(child.open, p) }),
        )
        |> list.map(fn(path) {
          json.object([
            #("uri", json.String(position.path_to_uri(path))),
            #("type", json.Int(2)),
          ])
        })
      let child = case changed {
        [] -> child
        _ ->
          send(
            child,
            "workspace/didChangeWatchedFiles",
            json.object([
              #("changes", json.Array(changed)),
            ]),
          )
      }
      put_child(state, child)
    }
  }
}

fn sync_open(child: Child, gleam_path: String, text: String) -> Child {
  let uri = position.path_to_uri(gleam_path)
  case dict.get(child.open, gleam_path) {
    Ok(#(_, existing)) if existing == text -> child
    Ok(#(version, _)) -> {
      let child =
        send(
          child,
          "textDocument/didChange",
          json.object([
            #(
              "textDocument",
              json.object([
                #("uri", json.String(uri)),
                #("version", json.Int(version + 1)),
              ]),
            ),
            #(
              "contentChanges",
              json.Array([json.object([#("text", json.String(text))])]),
            ),
          ]),
        )
      Child(
        ..child,
        open: dict.insert(child.open, gleam_path, #(version + 1, text)),
      )
    }
    Error(_) -> {
      let child =
        send(
          child,
          "textDocument/didOpen",
          json.object([
            #(
              "textDocument",
              json.object([
                #("uri", json.String(uri)),
                #("languageId", json.String("gleam")),
                #("version", json.Int(1)),
                #("text", json.String(text)),
              ]),
            ),
          ]),
        )
      Child(..child, open: dict.insert(child.open, gleam_path, #(1, text)))
    }
  }
}

fn bea_diagnostic(index: span.LineIndex, d: Diagnostic) -> Json {
  let message =
    d.title
    <> case d.label {
      "" -> ""
      label -> ": " <> label
    }
    <> case d.hint {
      Some(h) -> "\n" <> h
      None -> ""
    }
  json.object([
    #("range", position.span_to_range(index, d.span)),
    #(
      "severity",
      json.Int(case d.severity {
        diagnostic.Error -> 1
        diagnostic.Warning -> 2
      }),
    ),
    #("source", json.String("bea")),
    #("message", json.String(message)),
  ])
}

/// Publish the combined Bea and Gleam diagnostics of a source file.
fn publish(state: State, path: String) -> Nil {
  let bea = dict.get(state.bea_diagnostics, path) |> result.unwrap([])
  let has_errors =
    list.any(bea, fn(d) { json.int_at(d, ["severity"]) == Some(1) })
  // While Bea can't compile a file, Gleam's diagnostics for it are stale.
  let gleam = case has_errors {
    True -> []
    False -> dict.get(state.gleam_diagnostics, path) |> result.unwrap([])
  }
  notify_client(
    "textDocument/publishDiagnostics",
    json.object([
      #("uri", json.String(position.path_to_uri(path))),
      #("diagnostics", json.Array(list.append(bea, gleam))),
    ]),
  )
}

fn gleam_diagnostics(state: State, child: Child, params: Json) -> State {
  let uri = json.string_at(params, ["uri"]) |> option.unwrap("")
  let diagnostics = case json.get(params, "diagnostics") {
    Some(json.Array(ds)) -> ds
    _ -> []
  }
  case position.uri_to_path(uri) {
    None -> state
    Some(path) ->
      case
        dict.get(child.modules, path),
        project.original_path(child.project, path)
      {
        Ok(module), _ -> {
          let mapped =
            diagnostics
            |> list.filter(fn(d) {
              !string.contains(
                json.string_at(d, ["message"]) |> option.unwrap(""),
                placeholder,
              )
            })
            |> list.filter_map(fn(d) {
              case json.get(d, "range") {
                Some(range) ->
                  case map_range_to_bea(module.map, range) {
                    Some(r) ->
                      Ok(
                        d
                        |> json.set("range", r)
                        |> json.set("source", json.String("gleam"))
                        |> map_related(child),
                      )
                    None -> Error(Nil)
                  }
                None -> Error(Nil)
              }
            })
          let state =
            State(
              ..state,
              gleam_diagnostics: dict.insert(
                state.gleam_diagnostics,
                module.bea_path,
                mapped,
              ),
            )
          publish(state, module.bea_path)
          state
        }
        Error(_), Some(original) -> {
          notify_client(
            "textDocument/publishDiagnostics",
            json.set(params, "uri", json.String(position.path_to_uri(original))),
          )
          state
        }
        Error(_), None -> {
          notify_client("textDocument/publishDiagnostics", params)
          state
        }
      }
  }
}

fn map_related(d: Json, child: Child) -> Json {
  case json.get(d, "relatedInformation") {
    Some(json.Array(items)) ->
      json.set(
        d,
        "relatedInformation",
        json.Array(
          list.filter_map(items, fn(item) {
            case json.get(item, "location") {
              Some(loc) ->
                case map_location(child, loc, "uri", "range") {
                  Some(l) -> Ok(json.set(item, "location", l))
                  None -> Error(Nil)
                }
              None -> Ok(item)
            }
          }),
        ),
      )
    _ -> d
  }
}

// --- Position translation ------------------------------------------------------------

fn map_range_to_bea(map: SourceMap, range: Json) -> Option(Json) {
  let generated = position.range_to_span(map.gleam, range)
  case sourcemap.to_bea_span(map, generated) {
    Some(s) -> Some(position.span_to_range(map.bea, s))
    None -> None
  }
}

/// Translate a location (`uri_key`/`range_key` fields) from generated Gleam
/// to Bea. Locations in dependencies are left alone.
fn map_location(
  child: Child,
  location: Json,
  uri_key: String,
  range_key: String,
) -> Option(Json) {
  let uri = json.string_at(location, [uri_key]) |> option.unwrap("")
  case position.uri_to_path(uri) {
    None -> Some(location)
    Some(path) ->
      case
        dict.get(child.modules, path),
        project.original_path(child.project, path)
      {
        Ok(module), _ -> {
          let location =
            json.set(
              location,
              uri_key,
              json.String(position.path_to_uri(module.bea_path)),
            )
          case json.get(location, range_key) {
            Some(range) ->
              case map_range_to_bea(module.map, range) {
                Some(r) -> Some(json.set(location, range_key, r))
                None -> None
              }
            None -> Some(location)
          }
        }
        Error(_), Some(original) ->
          Some(json.set(
            location,
            uri_key,
            json.String(position.path_to_uri(original)),
          ))
        Error(_), None -> Some(location)
      }
  }
}

fn positional(state: State, id: Json, method: String, params: Json) -> State {
  let uri = json.string_at(params, ["textDocument", "uri"]) |> option.unwrap("")
  let path = position.uri_to_path(uri)
  let document =
    option.then(path, fn(p) { dict.get(state.docs, p) |> option.from_result })
  case path, document {
    Some(path), Some(document) -> {
      let #(state, key) = ensure_child(state, project_for(path))
      let state = case dict.get(state.children, key) {
        Ok(c) if c.dirty -> refresh(state, key)
        _ -> state
      }
      case dict.get(state.children, key) {
        Error(_) -> {
          respond(id, json.Null)
          state
        }
        Ok(child) ->
          case string.ends_with(path, ".bea") {
            True -> positional_bea(state, child, id, method, params, document)
            False ->
              positional_passthrough(state, child, id, method, params, path)
          }
      }
    }
    _, _ -> {
      respond(id, json.Null)
      state
    }
  }
}

fn forward(
  state: State,
  child: Child,
  id: Json,
  method: String,
  params: Json,
  pending: Pending,
) -> State {
  let child =
    send_message(
      child,
      json.object([
        #("jsonrpc", json.String("2.0")),
        #("id", id),
        #("method", json.String(method)),
        #("params", params),
      ]),
    )
  let state = put_child(state, child)
  State(..state, pending: dict.insert(state.pending, id_key(id), pending))
}

fn positional_passthrough(
  state: State,
  child: Child,
  id: Json,
  method: String,
  params: Json,
  path: String,
) -> State {
  let target = position.path_to_uri(project.copied_path(child.project, path))
  let params =
    json.update_at(params, ["textDocument"], json.set(
      _,
      "uri",
      json.String(target),
    ))
  forward(
    state,
    child,
    id,
    method,
    params,
    Pending(child.key, method, path, None, 0, None),
  )
}

fn positional_bea(
  state: State,
  child: Child,
  id: Json,
  method: String,
  params: Json,
  document: Document,
) -> State {
  let gleam_path = generated_path(child, document.path)
  let index = span.line_index(document.text)
  let offset = case json.get(params, "position") {
    Some(p) -> position.to_offset(index, p)
    None -> 0
  }
  let module = dict.get(child.modules, gleam_path) |> option.from_result
  let up_to_date = case module {
    Some(m) -> m.source == document.text
    None -> False
  }
  let before = before_cursor(document.text, offset)
  log(
    state,
    "positional "
      <> method
      <> " offset="
      <> int.to_string(offset)
      <> " up_to_date="
      <> string.inspect(up_to_date),
  )
  let wants_placeholder =
    method == "textDocument/completion"
    && { !up_to_date || !is_name_char(before) }
  case wants_placeholder, module, up_to_date {
    True, _, _ ->
      completion_with_placeholder(state, child, id, params, document, offset)
    False, Some(m), True ->
      case sourcemap.to_gleam_offset_inclusive(m.map, offset) {
        Some(gleam_offset) -> {
          let params =
            params
            |> json.update_at(["textDocument"], json.set(
              _,
              "uri",
              json.String(position.path_to_uri(gleam_path)),
            ))
            |> json.set(
              "position",
              position.from_offset(m.map.gleam, gleam_offset),
            )
          forward(
            state,
            child,
            id,
            method,
            params,
            Pending(child.key, method, document.path, Some(m.map), offset, None),
          )
        }
        None -> {
          respond(id, json.Null)
          state
        }
      }
    // The document doesn't compile right now, so positions can't be trusted.
    _, _, _ -> {
      respond(id, json.Null)
      state
    }
  }
}

fn before_cursor(text: String, offset: Int) -> String {
  case offset > 0 {
    True -> span.text(text, Span(offset - 1, offset))
    False -> ""
  }
}

fn is_name_char(c: String) -> Bool {
  c != ""
  && string.contains(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_",
    c,
  )
}

/// Complete at a position where the code doesn't currently parse (e.g. just
/// after `list.`) by compiling a copy with a placeholder name at the cursor.
fn completion_with_placeholder(
  state: State,
  child: Child,
  id: Json,
  params: Json,
  document: Document,
  offset: Int,
) -> State {
  let gleam_path = generated_path(child, document.path)
  let text = document.text
  let patched =
    span.text(text, Span(0, offset))
    <> placeholder
    <> span.text(text, Span(offset, string.byte_size(text)))
  log(state, "placeholder patch at " <> int.to_string(offset))
  case compiler.compile(patched, codegen.empty_context()) {
    Error(errs) -> {
      log(state, "placeholder compile failed: " <> string.inspect(errs))
      respond(id, json.Null)
      state
    }
    Ok(compiled) -> {
      let map = sourcemap.new(compiled.mappings, patched, compiled.gleam)
      case sourcemap.to_gleam_offset(map, offset) {
        None -> {
          respond(id, json.Null)
          state
        }
        Some(gleam_offset) -> {
          let child = sync_open(child, gleam_path, compiled.gleam)
          let params =
            params
            |> json.update_at(["textDocument"], json.set(
              _,
              "uri",
              json.String(position.path_to_uri(gleam_path)),
            ))
            |> json.set(
              "position",
              position.from_offset(map.gleam, gleam_offset),
            )
          forward(
            state,
            child,
            id,
            "textDocument/completion",
            params,
            Pending(
              child.key,
              "textDocument/completion",
              document.path,
              Some(map),
              offset,
              Some(gleam_path),
            ),
          )
        }
      }
    }
  }
}

fn child_response(
  state: State,
  child: Child,
  id: Json,
  message: Json,
) -> State {
  case dict.get(state.pending, id_key(id)) {
    Error(_) -> state
    Ok(pending) -> {
      let state =
        State(..state, pending: dict.delete(state.pending, id_key(id)))
      case json.get(message, "error") {
        Some(_) -> transport.send_client(message)
        None -> {
          let result = json.get(message, "result") |> option.unwrap(json.Null)
          log(
            state,
            pending.method
              <> " raw result: "
              <> string.slice(json.to_string(result), 0, 600),
          )
          let result = translate_result(state, child, pending, result)
          respond(id, result)
        }
      }
      // Put back the real generated code after a placeholder completion.
      case pending.restore {
        Some(gleam_path) ->
          case dict.get(child.modules, gleam_path) {
            Ok(m) -> {
              let assert Ok(child) = dict.get(state.children, child.key)
              put_child(state, sync_open(child, gleam_path, m.map.gleam_source))
            }
            Error(_) -> state
          }
        None -> state
      }
    }
  }
}

fn translate_result(
  state: State,
  child: Child,
  pending: Pending,
  result: Json,
) -> Json {
  let map_range = fn(range: Json) {
    case pending.map {
      Some(map) -> map_range_to_bea(map, range)
      None -> Some(range)
    }
  }
  let locations = fn(r: Json) {
    case r {
      json.Array(items) ->
        json.Array(
          list.filter_map(items, fn(item) {
            case json.get(item, "targetUri") {
              Some(_) ->
                case map_location(child, item, "targetUri", "targetRange") {
                  Some(l) -> {
                    let l = case
                      map_location(
                        child,
                        l,
                        "targetUri",
                        "targetSelectionRange",
                      )
                    {
                      Some(l2) -> l2
                      None -> l
                    }
                    Ok(
                      json.update_at(l, ["originSelectionRange"], fn(r) {
                        map_range(r) |> option.unwrap(r)
                      }),
                    )
                  }
                  None -> Error(Nil)
                }
              None ->
                option.to_result(map_location(child, item, "uri", "range"), Nil)
            }
          }),
        )
      json.Object(_) ->
        map_location(child, r, "uri", "range") |> option.unwrap(json.Null)
      other -> other
    }
  }
  let result = case pending.method {
    "textDocument/hover"
    | "textDocument/completion"
    | "textDocument/signatureHelp" -> bea_types(result)
    _ -> result
  }
  case pending.method {
    "textDocument/hover" ->
      case json.get(result, "range") {
        Some(range) ->
          case map_range(range) {
            Some(r) -> json.set(result, "range", r)
            None ->
              json.Object(list.filter(fields(result), fn(f) { f.0 != "range" }))
          }
        None -> result
      }
    "textDocument/definition"
    | "textDocument/typeDefinition"
    | "textDocument/references" -> locations(result)
    "textDocument/documentHighlight" ->
      case result {
        json.Array(items) ->
          json.Array(
            list.filter_map(items, fn(item) {
              case json.get(item, "range") {
                Some(range) ->
                  case map_range(range) {
                    Some(r) -> Ok(json.set(item, "range", r))
                    None -> Error(Nil)
                  }
                None -> Error(Nil)
              }
            })
            |> list.unique,
          )
        other -> other
      }
    "textDocument/prepareRename" ->
      case json.get(result, "range"), json.get(result, "start") {
        Some(range), _ ->
          case map_range(range) {
            Some(r) -> json.set(result, "range", r)
            None -> json.Null
          }
        None, Some(_) -> map_range(result) |> option.unwrap(json.Null)
        None, None -> result
      }
    "textDocument/rename" -> rename_edit(child, result)
    "textDocument/completion" -> completion(state, child, pending, result)
    _ -> result
  }
}

/// Gleam writes tuple types as `#(A, B)`; Bea writes `(A, B)`. Rewrite the
/// human readable parts of hovers, completion details and signatures.
fn bea_types(j: Json) -> Json {
  case j {
    json.String(s) -> json.String(string.replace(s, "#(", "("))
    json.Array(items) -> json.Array(list.map(items, bea_types))
    json.Object(fs) ->
      json.Object(
        list.map(fs, fn(f) {
          case f.0 {
            "value"
            | "contents"
            | "detail"
            | "label"
            | "documentation"
            | "signatures"
            | "parameters"
            | "labelDetails"
            | "description" -> #(f.0, bea_types(f.1))
            _ -> f
          }
        }),
      )
    other -> other
  }
}

fn fields(j: Json) -> List(#(String, Json)) {
  case j {
    json.Object(fs) -> fs
    _ -> []
  }
}

fn rename_edit(child: Child, edit: Json) -> Json {
  let map_edits = fn(uri: String, edits: List(Json)) -> #(String, List(Json)) {
    let mapped =
      edits
      |> list.filter_map(fn(e) {
        let as_location = json.set(e, "uri", json.String(uri))
        case map_location(child, as_location, "uri", "range") {
          Some(l) ->
            Ok(#(
              json.string_at(l, ["uri"]) |> option.unwrap(uri),
              json.set(
                e,
                "range",
                json.get(l, "range") |> option.unwrap(json.Null),
              ),
            ))
          None -> Error(Nil)
        }
      })
    let new_uri = case mapped {
      [#(u, _), ..] -> u
      [] -> uri
    }
    #(new_uri, list.map(mapped, fn(m) { m.1 }) |> list.unique)
  }
  case json.get(edit, "changes"), json.get(edit, "documentChanges") {
    Some(json.Object(changes)), _ ->
      json.object([
        #(
          "changes",
          json.Object(
            list.map(changes, fn(c) {
              let edits = case c.1 {
                json.Array(es) -> es
                _ -> []
              }
              let #(uri, edits) = map_edits(c.0, edits)
              #(uri, json.Array(edits))
            }),
          ),
        ),
      ])
    _, Some(json.Array(changes)) ->
      json.object([
        #(
          "documentChanges",
          json.Array(
            list.map(changes, fn(c) {
              let uri =
                json.string_at(c, ["textDocument", "uri"]) |> option.unwrap("")
              let edits = case json.get(c, "edits") {
                Some(json.Array(es)) -> es
                _ -> []
              }
              let #(uri, edits) = map_edits(uri, edits)
              json.object([
                #(
                  "textDocument",
                  json.object([
                    #("uri", json.String(uri)),
                    #("version", json.Null),
                  ]),
                ),
                #("edits", json.Array(edits)),
              ])
            }),
          ),
        ),
      ])
    _, _ -> edit
  }
}

/// Standard library modules Bea imports automatically.
const auto_imported = [
  "gleam/list", "gleam/dict", "gleam/set", "gleam/string", "gleam/int",
  "gleam/float", "gleam/result", "gleam/option", "gleam/io", "gleam/bool",
  "gleam/order", "gleam/pair", "gleam/function", "gleam/bit_array",
  "gleam/bytes_tree", "gleam/string_tree", "gleam/dynamic",
  "gleam/dynamic/decode", "gleam/uri",
]

fn completion(
  state: State,
  child: Child,
  pending: Pending,
  result: Json,
) -> Json {
  let _ = child
  let document = dict.get(state.docs, pending.path)
  let bea_index = case document {
    Ok(d) -> span.line_index(d.text)
    Error(_) -> span.line_index("")
  }
  let import_offset = case document {
    Ok(d) -> import_insertion_offset(d.text)
    Error(_) -> 0
  }
  let fix_range = fn(range: Json) -> Option(Json) {
    case pending.map {
      None -> Some(range)
      Some(map) -> {
        let generated = position.range_to_span(map.gleam, range)
        let start = sourcemap.to_bea_offset(map, generated.start)
        let start = case start {
          Some(s) -> Some(int.min(s, pending.cursor))
          None ->
            case generated.start == generated.end {
              True -> Some(pending.cursor)
              False -> None
            }
        }
        case start {
          Some(s) ->
            Some(position.span_to_range(bea_index, Span(s, pending.cursor)))
          None -> None
        }
      }
    }
  }
  let fix_item = fn(item: Json) -> Json {
    let item = case json.get(item, "textEdit") {
      Some(edit) ->
        case json.get(edit, "range"), json.get(edit, "insert") {
          Some(range), _ ->
            case fix_range(range) {
              Some(r) -> json.set(item, "textEdit", json.set(edit, "range", r))
              None -> drop_field(item, "textEdit")
            }
          None, Some(insert) ->
            case fix_range(insert) {
              Some(r) ->
                json.set(
                  item,
                  "textEdit",
                  edit |> json.set("insert", r) |> json.set("replace", r),
                )
              None -> drop_field(item, "textEdit")
            }
          None, None -> item
        }
      None -> item
    }
    case json.get(item, "additionalTextEdits") {
      Some(json.Array(edits)) ->
        json.set(
          item,
          "additionalTextEdits",
          json.Array(
            list.filter_map(edits, fn(e) {
              let text = json.string_at(e, ["newText"]) |> option.unwrap("")
              case string.starts_with(string.trim_start(text), "import ") {
                False -> Error(Nil)
                True -> {
                  let module =
                    string.trim(text)
                    |> string.drop_start(7)
                    |> string.split(".")
                    |> list.first
                    |> result.unwrap("")
                  case list.contains(auto_imported, string.trim(module)) {
                    True -> Error(Nil)
                    False ->
                      Ok(
                        json.object([
                          #(
                            "range",
                            position.span_to_range(
                              bea_index,
                              Span(import_offset, import_offset),
                            ),
                          ),
                          #("newText", json.String(string.trim(text) <> "\n")),
                        ]),
                      )
                  }
                }
              }
            }),
          ),
        )
      _ -> item
    }
  }
  let not_placeholder = fn(item: Json) {
    !string.contains(
      json.string_at(item, ["label"]) |> option.unwrap(""),
      placeholder,
    )
  }
  case result {
    json.Array(items) ->
      json.Array(items |> list.filter(not_placeholder) |> list.map(fix_item))
    json.Object(_) ->
      case json.get(result, "items") {
        Some(json.Array(items)) ->
          json.set(
            result,
            "items",
            json.Array(
              items |> list.filter(not_placeholder) |> list.map(fix_item),
            ),
          )
        _ -> result
      }
    other -> other
  }
}

fn drop_field(j: Json, key: String) -> Json {
  json.Object(list.filter(fields(j), fn(f) { f.0 != key }))
}

/// Where a new import goes: after the last import, or at the top.
fn import_insertion_offset(text: String) -> Int {
  let lines = string.split(text, "\n")
  let #(_, offset, last_import_end) =
    list.fold(lines, #(0, 0, -1), fn(acc, line) {
      let #(i, start, last) = acc
      let end = start + string.byte_size(line) + 1
      let last = case string.starts_with(line, "import ") {
        True -> end
        False -> last
      }
      #(i + 1, end, last)
    })
  let _ = offset
  case last_import_end {
    -1 -> 0
    n -> int.min(n, string.byte_size(text))
  }
}

// --- Native features ------------------------------------------------------------------

fn format(state: State, id: Json, params: Json) -> Nil {
  let uri = json.string_at(params, ["textDocument", "uri"]) |> option.unwrap("")
  let document =
    position.uri_to_path(uri)
    |> option.then(fn(p) { dict.get(state.docs, p) |> option.from_result })
  case document {
    Some(d) ->
      case string.ends_with(d.path, ".bea"), formatter.format(d.text) {
        True, Ok(formatted) if formatted == d.text -> respond(id, json.Array([]))
        True, Ok(formatted) -> {
          let index = span.line_index(d.text)
          respond(
            id,
            json.Array([
              json.object([
                #(
                  "range",
                  position.span_to_range(
                    index,
                    Span(0, string.byte_size(d.text)),
                  ),
                ),
                #("newText", json.String(formatted)),
              ]),
            ]),
          )
        }
        _, _ -> respond(id, json.Null)
      }
    None -> respond(id, json.Null)
  }
}

fn document_symbols(state: State, id: Json, params: Json) -> Nil {
  let uri = json.string_at(params, ["textDocument", "uri"]) |> option.unwrap("")
  let document =
    position.uri_to_path(uri)
    |> option.then(fn(p) { dict.get(state.docs, p) |> option.from_result })
  case document {
    Some(d) -> {
      let parsed = parser.parse_module(d.text)
      respond(
        id,
        symbols.document_symbols(parsed.module, span.line_index(d.text)),
      )
    }
    None -> respond(id, json.Array([]))
  }
}
