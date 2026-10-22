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
//// - Requests while the code doesn't compile (right after `list.`, inside
////   an unfinished call, ...) are answered on a repaired copy of the buffer
////   (see `bea/lsp/repair`): a placeholder name at the cursor, open brackets
////   closed, the rest of the definition dropped if need be.
//// - Answers are enriched from an index of the project and its
////   dependencies (`bea/lsp/index`): parameter names in signature help and
////   hovers, completions of functions from modules that aren't imported yet
////   (adding the import), and `@external` functions in `.erl` / `.mjs` files.
////
//// One `gleam lsp` child is started per Bea project (or per folder of loose
//// `.bea` files).

import bea/codegen
import bea/compiler
import bea/diagnostic.{type Diagnostic}
import bea/formatter
import bea/imports
import bea/lsp/assist
import bea/lsp/index
import bea/lsp/json.{type Json}
import bea/lsp/position
import bea/lsp/repair
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
import gleam/order
import gleam/result
import gleam/string
import simplifile

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
    /// Code generation context of the last sync.
    context: codegen.Context,
    /// Public values of the dependencies, read on first use.
    deps_index: Option(index.Index),
    /// Generated documents currently replaced by a repaired copy in
    /// `gleam lsp` (their diagnostics are meaningless until restored).
    patched: List(String),
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
    /// Generated module to restore after a request on a repaired copy.
    restore: Option(String),
    /// Signature help is answered from a hover on the called function
    /// (`gleam lsp` has no signature while the cursor is on an argument).
    call: Option(repair.Call),
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
    /// The client accepts snippets in completions.
    snippets: Bool,
    /// Complete functions with `()` and show their signature.
    call_parens: Bool,
    /// Organise imports when formatting (see `bea/imports`).
    organize_imports: Bool,
  )
}

pub fn main() -> Int {
  system.no_foreground()
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
      snippets: False,
      call_parens: True,
      organize_imports: True,
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
        #("retriggerCharacters", json.Array([json.String(" ")])),
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
      let snippets =
        json.at(params, [
          "capabilities", "textDocument", "completion", "completionItem",
          "snippetSupport",
        ])
        == Some(json.Bool(True))
      let call_parens = case
        json.at(params, [
          "initializationOptions",
          "completion",
          "callParentheses",
        ])
      {
        Some(json.Bool(False)) -> False
        _ -> True
      }
      let organize_imports = case
        json.at(params, ["initializationOptions", "format", "organizeImports"])
      {
        Some(json.Bool(False)) -> False
        _ -> True
      }
      let state =
        State(
          ..state,
          init_params: params,
          snippets:,
          call_parens:,
          organize_imports:,
        )
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
    "textDocument/formatting" -> format(state, id, params)
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
              context: sync.context,
              deps_index: None,
              patched: [],
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
      let child = Child(..child, project: p, dirty: True, deps_index: None)
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
      let child =
        Child(
          ..child,
          modules:,
          cache:,
          dirty: False,
          errored:,
          context: sync.context,
        )
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
  sync_open_(child, gleam_path, text, False)
}

/// `force` sends the text even when Gleam has it already, to have the
/// module checked (and its diagnostics published) again.
fn sync_open_(
  child: Child,
  gleam_path: String,
  text: String,
  force: Bool,
) -> Child {
  let uri = position.path_to_uri(gleam_path)
  case dict.get(child.open, gleam_path) {
    Ok(#(_, existing)) if existing == text && !force -> child
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
        // While a repaired copy is open, diagnostics of any module can be
        // about it (the copy may drop definitions other modules use). The
        // real ones are published again after the restore.
        Ok(_), _ if child.patched != [] -> state
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
        Ok(child) -> {
          let child = case method {
            "textDocument/completion"
            | "textDocument/signatureHelp"
            | "textDocument/hover" -> with_deps_index(child)
            _ -> child
          }
          let state = put_child(state, child)
          case foreign(state, child, id, method, params, document) {
            True -> state
            False ->
              case string.ends_with(path, ".bea") {
                True ->
                  positional_bea(state, child, id, method, params, document)
                False ->
                  positional_passthrough(state, child, id, method, params, path)
              }
          }
        }
      }
    }
    _, _ -> {
      respond(id, json.Null)
      state
    }
  }
}

fn with_deps_index(child: Child) -> Child {
  // Read again while empty: dependencies may not have been downloaded yet.
  case child.deps_index {
    Some(i) ->
      case dict.is_empty(i) {
        False -> child
        True ->
          Child(..child, deps_index: Some(index.dependencies(child.project)))
      }
    None -> Child(..child, deps_index: Some(index.dependencies(child.project)))
  }
}

/// Go to definition / hover on an `@external(...)`: answered from the Erlang
/// or JavaScript source, which `gleam lsp` doesn't look into.
fn foreign(
  state: State,
  child: Child,
  id: Json,
  method: String,
  params: Json,
  document: Document,
) -> Bool {
  let _ = state
  case method {
    "textDocument/definition" | "textDocument/hover" -> {
      let index = span.line_index(document.text)
      let offset = case json.get(params, "position") {
        Some(p) -> position.to_offset(index, p)
        None -> 0
      }
      let found =
        assist.external_at(document.text, offset)
        |> option.then(fn(e) {
          case e.target {
            "erlang" -> index.find_erlang(child.project, e.module, e.function)
            _ ->
              index.find_javascript(
                project.dirname(document.path),
                e.module,
                e.function,
              )
          }
        })
      case found, method {
        None, _ -> False
        Some(f), "textDocument/definition" -> {
          let at =
            json.object([
              #("line", json.Int(f.line)),
              #("character", json.Int(0)),
            ])
          respond(
            id,
            json.object([
              #("uri", json.String(position.path_to_uri(f.path))),
              #("range", json.object([#("start", at), #("end", at)])),
            ]),
          )
          True
        }
        Some(f), _ -> {
          respond(
            id,
            json.object([
              #(
                "contents",
                json.object([
                  #("kind", json.String("markdown")),
                  #(
                    "value",
                    json.String(assist.foreign_markdown(
                      f,
                      display_path(child, f.path),
                    )),
                  ),
                ]),
              ),
            ]),
          )
          True
        }
      }
    }
    _ -> False
  }
}

fn display_path(child: Child, path: String) -> String {
  let root = child.project.root <> "/"
  let packages = child.project.build_dir <> "/build/packages/"
  case string.starts_with(path, packages), string.starts_with(path, root) {
    True, _ -> string.drop_start(path, string.length(packages))
    _, True -> string.drop_start(path, string.length(root))
    _, _ -> path
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
    Pending(child.key, method, path, None, 0, None, None),
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
  case method, module, up_to_date {
    "textDocument/completion", _, _ ->
      case repair.in_text(document.text, offset) {
        // Nothing to complete in comments and strings.
        True -> {
          respond(id, json.Array([]))
          state
        }
        False ->
          case up_to_date && is_name_char(before) {
            True ->
              forward_at(state, child, id, method, params, document, offset)
            False ->
              repaired(
                state,
                child,
                id,
                method,
                params,
                document,
                offset,
                offset,
                placeholder,
              )
          }
      }
    "textDocument/signatureHelp", _, _ ->
      case repair.call_at(document.text, offset) {
        Error(_) -> {
          respond(id, json.Null)
          state
        }
        Ok(call) -> {
          let params =
            json.set(
              params,
              "position",
              position.from_offset(index, call.name_start),
            )
          let state = case up_to_date {
            True ->
              forward_at(
                state,
                child,
                id,
                "textDocument/hover",
                params,
                document,
                call.name_start,
              )
            False ->
              repaired(
                state,
                child,
                id,
                "textDocument/hover",
                params,
                document,
                call.name_start,
                offset,
                "",
              )
          }
          // Answer as signature help when the hover comes back.
          State(
            ..state,
            // (Nothing is pending when it was answered `null` already.)
            pending: case dict.get(state.pending, id_key(id)) {
              Ok(p) ->
                dict.insert(
                  state.pending,
                  id_key(id),
                  Pending(
                    ..p,
                    method: "textDocument/signatureHelp",
                    call: Some(call),
                  ),
                )
              Error(_) -> state.pending
            },
          )
        }
      }
    "textDocument/hover", _, False
    | "textDocument/definition", _, False
    | "textDocument/typeDefinition", _, False
    ->
      // Keep the whole name under the cursor, repair after it.
      repaired(
        state,
        child,
        id,
        method,
        params,
        document,
        offset,
        repair.word_end(document.text, offset),
        "",
      )
    _, Some(_), True ->
      forward_at(state, child, id, method, params, document, offset)
    // The document doesn't compile right now, so positions can't be trusted.
    _, _, _ -> {
      respond(id, json.Null)
      state
    }
  }
}

/// Forward a request about an up to date document to `gleam lsp`.
fn forward_at(
  state: State,
  child: Child,
  id: Json,
  method: String,
  params: Json,
  document: Document,
  offset: Int,
) -> State {
  let gleam_path = generated_path(child, document.path)
  case dict.get(child.modules, gleam_path) {
    Error(_) -> {
      respond(id, json.Null)
      state
    }
    Ok(m) ->
      case
        case method {
          "textDocument/completion" ->
            sourcemap.to_gleam_offset_after(m.map, offset)
            |> option.map(inside_word(m.map.gleam_source, _))
          _ -> sourcemap.to_gleam_offset_inclusive(m.map, offset)
        }
      {
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
            Pending(
              child.key,
              method,
              document.path,
              Some(m.map),
              offset,
              None,
              None,
            ),
          )
        }
        None -> {
          respond(id, json.Null)
          state
        }
      }
  }
}

/// Completion requests go to Gleam one byte *inside* the name being typed
/// rather than right after it. Gleam leaves out the variables bound by a
/// `use` when the cursor sits at the very end of its body — and Bea turns
/// every `x = f()?` and early `return` into a `use`, so the variables bound
/// before them went missing from completions on the line being written.
/// Gleam takes the whole name around the cursor either way.
fn inside_word(gleam: String, offset: Int) -> Int {
  case offset > 0 && is_name_char(span.text(gleam, Span(offset - 1, offset))) {
    True -> offset - 1
    False -> offset
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

/// Answer a request on a repaired copy of a document that doesn't compile
/// as it is (see `bea/lsp/repair`): `hole` is inserted at `at`, and the
/// request is made at `offset`. The copy is shown to `gleam lsp` for the
/// duration of the request, then the real generated code is put back.
fn repaired(
  state: State,
  child: Child,
  id: Json,
  method: String,
  params: Json,
  document: Document,
  offset: Int,
  at: Int,
  hole: String,
) -> State {
  let gleam_path = generated_path(child, document.path)
  let compiled =
    repair.candidates(document.text, at, hole)
    |> list.find_map(fn(patched) {
      compiler.compile(patched, child.context)
      |> result.map(fn(c) { #(patched, c) })
      |> result.replace_error(Nil)
    })
  case compiled {
    Error(_) -> {
      log(state, "no repair compiles for " <> method)
      respond(id, json.Null)
      state
    }
    Ok(#(patched, compiled)) -> {
      let map = sourcemap.new(compiled.mappings, patched, compiled.gleam)
      let gleam_offset = case hole {
        "" -> sourcemap.to_gleam_offset_inclusive(map, offset)
        _ -> sourcemap.to_gleam_offset(map, offset)
      }
      case gleam_offset {
        None -> {
          respond(id, json.Null)
          state
        }
        Some(gleam_offset) -> {
          let child = sync_open(child, gleam_path, compiled.gleam)
          let child = case list.contains(child.patched, gleam_path) {
            True -> child
            False -> Child(..child, patched: [gleam_path, ..child.patched])
          }
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
            method,
            params,
            Pending(
              child.key,
              method,
              document.path,
              Some(map),
              offset,
              Some(gleam_path),
              None,
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
      // Put back the real generated code after a request on a repaired copy.
      case pending.restore {
        Some(gleam_path) -> {
          let assert Ok(child) = dict.get(state.children, child.key)
          let still_pending =
            dict.values(state.pending)
            |> list.any(fn(p) { p.restore == Some(gleam_path) })
          case still_pending, dict.get(child.modules, gleam_path) {
            True, _ -> state
            False, Ok(m) -> {
              let child =
                sync_open_(child, gleam_path, m.map.gleam_source, True)
              let patched =
                list.filter(child.patched, fn(p) { p != gleam_path })
              put_child(state, Child(..child, patched:))
            }
            False, Error(_) -> {
              let patched =
                list.filter(child.patched, fn(p) { p != gleam_path })
              put_child(state, Child(..child, patched:))
            }
          }
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
  // Gleam answered on a repaired copy: its positions in that module are
  // positions in the copy.
  let child = case pending.restore, pending.map {
    Some(gleam_path), Some(map) ->
      Child(
        ..child,
        modules: dict.upsert(child.modules, gleam_path, fn(m) {
          case m {
            Some(m) -> project.Module(..m, map:)
            None ->
              project.Module(
                project.module_name(child.project, pending.path),
                pending.path,
                gleam_path,
                map.bea_source,
                map,
              )
          }
        }),
      )
    _, _ -> child
  }
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
  let bea = string.ends_with(pending.path, ".bea")
  let result = case pending.method {
    _ if !bea -> result
    "textDocument/completion" -> bea_types(result)
    "textDocument/hover" -> hover(state, child, pending, result)
    "textDocument/signatureHelp" ->
      case pending.call {
        Some(call) -> signature_from_hover(state, child, pending, call, result)
        None -> signature_help(state, child, pending, result)
      }
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
    "textDocument/completion" if bea -> completion(state, child, pending, result)
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

// --- Enriching Gleam's answers ------------------------------------------------------

/// Look up a declaration in the project (Bea and Gleam modules) or its
/// dependencies.
fn lookup(child: Child) -> fn(String, String) -> Option(index.Entry) {
  fn(module, name) {
    case project_entries(child, module) {
      Some(entries) ->
        list.find(entries, fn(e) { e.name == name }) |> option.from_result
      None ->
        case child.deps_index {
          Some(deps) -> index.lookup(deps, module, name)
          None -> None
        }
    }
  }
}

/// Public values of one of the project's own modules.
fn project_entries(child: Child, module: String) -> Option(List(index.Entry)) {
  let bea = child.project.build_dir <> "/src/" <> module <> ".gleam"
  case dict.get(child.modules, bea) {
    Ok(m) -> Some(index.from_bea(module, parser.parse_module(m.source).module))
    Error(_) -> {
      let gleam = child.project.src_dir <> "/" <> module <> ".gleam"
      case system.file_exists(gleam) {
        False -> None
        True ->
          simplifile.read(gleam)
          |> result.map(index.from_gleam(module, _))
          |> option.from_result
      }
    }
  }
}

fn current_module(child: Child, document: Document) -> String {
  project.module_name(child.project, document.path)
}

fn hover(state: State, child: Child, pending: Pending, result: Json) -> Json {
  case dict.get(state.docs, pending.path) {
    Error(_) -> bea_types(result)
    Ok(document) -> {
      let #(qualifier, name, _, _) =
        repair.qualified_name_at(document.text, pending.cursor)
      let entry =
        assist.resolve(
          assist.imports(document.text),
          current_module(child, document),
          qualifier,
          name,
          lookup(child),
        )
      let rewrite = fn(contents: String) {
        assist.hover(contents, entry, qualifier)
      }
      case json.get(result, "contents") {
        Some(json.String(c)) ->
          json.set(result, "contents", json.String(rewrite(c)))
        Some(json.Object(_) as markup) ->
          json.set(
            result,
            "contents",
            json.update_at(markup, ["value"], fn(v) {
              case v {
                json.String(c) -> json.String(rewrite(c))
                other -> other
              }
            }),
          )
        _ -> bea_types(result)
      }
    }
  }
}

fn signature_help(
  state: State,
  child: Child,
  pending: Pending,
  result: Json,
) -> Json {
  let imports = case dict.get(state.docs, pending.path) {
    Ok(d) -> Some(#(assist.imports(d.text), current_module(child, d)))
    Error(_) -> None
  }
  case json.get(result, "signatures") {
    Some(json.Array(signatures)) ->
      json.set(
        result,
        "signatures",
        json.Array(
          list.map(signatures, fn(sig) {
            let entry = case imports {
              Some(#(imports, module)) -> {
                let #(qualifier, name) = assist.signature_target(sig)
                assist.resolve(imports, module, qualifier, name, lookup(child))
              }
              None -> None
            }
            assist.signature(sig, entry)
          }),
        ),
      )
    _ -> result
  }
}

/// Build signature help from the hover of the called function: its type
/// (from Gleam), parameter names (from the declaration), its docs, and the
/// argument the cursor is in (counted in the Bea source).
fn signature_from_hover(
  state: State,
  child: Child,
  pending: Pending,
  call: repair.Call,
  result: Json,
) -> Json {
  let contents = case json.get(result, "contents") {
    Some(json.String(c)) -> c
    Some(json.Object(_) as markup) ->
      json.string_at(markup, ["value"]) |> option.unwrap("")
    _ -> ""
  }
  let #(code, docs) = case string.split_once(contents, "```gleam\n") {
    Ok(#(_, after)) ->
      case string.split_once(after, "\n```") {
        Ok(#(code, docs)) -> #(code, string.trim(docs))
        Error(_) -> #(after, "")
      }
    Error(_) -> #("", "")
  }
  case assist.fn_type(assist.bea_type(code)) {
    None -> json.Null
    Some(#(types, ret)) -> {
      let entry = case dict.get(state.docs, pending.path) {
        Ok(d) ->
          assist.resolve(
            assist.imports(d.text),
            current_module(child, d),
            call.qualifier,
            call.name,
            lookup(child),
          )
        Error(_) -> None
      }
      let declared = case entry {
        Some(e) -> e.params
        None -> []
      }
      let shown =
        list.index_map(types, fn(t, i) {
          case list.drop(declared, i) {
            [d, ..] -> index.param_string(index.Param(d.label, d.name, t))
            [] -> t
          }
        })
      let active = case call.label {
        Ok(l) ->
          declared
          |> list.index_map(fn(d, i) { #(d, i) })
          |> list.find(fn(d) { d.0.label == Some(l) || d.0.name == l })
          |> result.map(fn(d) { d.1 })
          |> result.unwrap(call.argument)
        Error(_) -> call.argument
      }
      let name = case call.qualifier {
        Ok(q) -> q <> "." <> call.name
        Error(_) -> call.name
      }
      let head = name <> "("
      let #(parameters, _) =
        list.fold(shown, #([], span.utf16_length(head)), fn(acc, p) {
          let #(items, at) = acc
          let end = at + span.utf16_length(p)
          #(
            [
              json.object([
                #("label", json.Array([json.Int(at), json.Int(end)])),
              ]),
              ..items
            ],
            end + 2,
          )
        })
      let label =
        head
        <> string.join(shown, ", ")
        <> ")"
        <> case ret {
          "" -> ""
          r -> " -> " <> r
        }
      let documentation = case docs, entry {
        "", Some(e) -> e.doc
        d, _ -> d
      }
      json.object([
        #(
          "signatures",
          json.Array([
            json.object([
              #("label", json.String(label)),
              #(
                "documentation",
                json.object([
                  #("kind", json.String("markdown")),
                  #("value", json.String(documentation)),
                ]),
              ),
              #("parameters", json.Array(list.reverse(parameters))),
              #("activeParameter", json.Int(active)),
            ]),
          ]),
        ),
        #("activeSignature", json.Int(0)),
        #("activeParameter", json.Int(active)),
      ])
    }
  }
}

// --- Completion ---------------------------------------------------------------------

const kind_function = 3

const kind_constructor = 4

const kind_variable = 6

const kind_constant = 21

fn completion(
  state: State,
  child: Child,
  pending: Pending,
  result: Json,
) -> Json {
  let #(text, bea_index, import_offset) = case
    dict.get(state.docs, pending.path)
  {
    Ok(d) -> #(d.text, span.line_index(d.text), import_insertion_offset(d.text))
    Error(_) -> #("", span.line_index(""), 0)
  }
  let cursor = pending.cursor
  // The name being typed, and the module qualifier before it (`timestamp.`).
  let word = repair.word_start(text, cursor)
  let qualified = case repair.char_before(text, word) {
    "." -> repair.word_start(text, word - 1)
    _ -> word
  }
  let line = repair.line_before(text, cursor)
  let in_import = string.starts_with(line, "import ")
  // `import gleam/ti|` completes the whole module path.
  let path_start = cursor - string.byte_size(string.drop_start(line, 7))
  let range_for = fn(new_text: String) {
    let start = case in_import, string.contains(new_text, ".") {
      True, _ ->
        case string.contains(new_text, "/") || !string.contains(line, ".{") {
          True -> int.max(path_start, 0)
          False -> word
        }
      False, True -> qualified
      False, False -> word
    }
    position.span_to_range(bea_index, Span(start, cursor))
  }
  let next = repair.char_at(text, repair.word_end(text, cursor))
  let piped =
    string.ends_with(string.trim_end(repair.slice(text, 0, qualified)), "|>")
  let import_edit = fn(module: String) {
    json.object([
      #(
        "range",
        position.span_to_range(bea_index, Span(import_offset, import_offset)),
      ),
      #("newText", json.String("import " <> module <> "\n")),
    ])
  }
  // `name()` / `name($0)` and the signature popping up, for calls.
  let callable = fn(item: Json, new_text: String) -> Json {
    let kind = json.int_at(item, ["kind"]) |> option.unwrap(0)
    let detail = json.string_at(item, ["detail"]) |> option.unwrap("")
    let arity = assist.arity(detail)
    case
      state.snippets && state.call_parens && !in_import && next != "(",
      kind == kind_function || kind == kind_constructor,
      arity
    {
      True, True, Some(n) if !{ piped && n <= 1 } -> {
        let piped_args = case piped {
          True -> n - 1
          False -> n
        }
        let snippet = case piped_args {
          0 -> new_text <> "()"
          _ -> new_text <> "($0)"
        }
        let item =
          item
          |> json.set("insertTextFormat", json.Int(2))
          |> json.set(
            "textEdit",
            json.object([
              #("range", range_for(new_text)),
              #("newText", json.String(snippet)),
            ]),
          )
        case piped_args {
          0 -> item
          _ ->
            json.set(
              item,
              "command",
              json.object([
                #("title", json.String("Signature help")),
                #("command", json.String("editor.action.triggerParameterHints")),
              ]),
            )
        }
      }
      _, _, _ -> item
    }
  }
  let fix_item = fn(item: Json) -> Json {
    let label = json.string_at(item, ["label"]) |> option.unwrap("")
    let new_text =
      json.string_at(item, ["textEdit", "newText"])
      |> option.lazy_unwrap(fn() {
        json.string_at(item, ["insertText"]) |> option.unwrap(label)
      })
    let item =
      item
      |> drop_field("insertText")
      |> json.set(
        "textEdit",
        json.object([
          #("range", range_for(new_text)),
          #("newText", json.String(new_text)),
        ]),
      )
    let item = callable(item, new_text)
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
                    |> string.trim
                  case list.contains(assist.auto_imported, module) {
                    True -> Error(Nil)
                    False -> Ok(import_edit(module))
                  }
                }
              }
            }),
          ),
        )
      _ -> item
    }
  }
  // Names that only exist in the generated Gleam.
  let wanted = fn(item: Json) {
    let label = json.string_at(item, ["label"]) |> option.unwrap("")
    let kind = json.int_at(item, ["kind"]) |> option.unwrap(0)
    !string.contains(label, placeholder)
    && !string.starts_with(label, "bea_")
    && !string.contains(label, ".bea_")
    && !{
      kind == kind_variable
      && string.starts_with(label, "arg_")
      && !string.contains(text, label)
    }
  }
  let gleam_items = case result {
    json.Array(items) -> items
    json.Object(_) ->
      case json.get(result, "items") {
        Some(json.Array(items)) -> items
        _ -> []
      }
    _ -> []
  }
  let items =
    gleam_items
    |> list.filter(wanted)
    |> list.map(bea_types)
    |> list.map(fix_item)
  // Values from modules that aren't imported yet, for a bare name.
  let prefix = repair.slice(text, word, cursor)
  let #(extra, truncated) = case
    prefix != "" && word == qualified && !in_import
  {
    False -> #([], False)
    True -> {
      let offered =
        list.filter_map(items, fn(i) {
          json.string_at(i, ["textEdit", "newText"]) |> option.to_result(Nil)
        })
      unimported(child, text, pending.path, prefix, offered)
    }
  }
  let extra =
    list.map(extra, fn(e) {
      let #(entry, qualifier, sort) = e
      let new_text = qualifier <> "." <> entry.name
      let kind = case entry.kind {
        index.Function -> kind_function
        index.Constructor -> kind_constructor
        index.Constant -> kind_constant
      }
      let detail = case entry.kind {
        index.Function ->
          "fn("
          <> string.join(list.map(entry.params, index.param_string), ", ")
          <> ")"
          <> case entry.return_type {
            "" -> ""
            r -> " -> " <> r
          }
        index.Constructor -> index.signature(entry, None)
        index.Constant -> entry.return_type
      }
      let edits = case list.contains(assist.auto_imported, entry.module) {
        True -> []
        False -> [import_edit(entry.module)]
      }
      json.object([
        #("label", json.String(entry.name)),
        #("kind", json.Int(kind)),
        #("detail", json.String(assist.bea_type(detail))),
        #(
          "labelDetails",
          json.object([#("description", json.String(entry.module))]),
        ),
        #(
          "documentation",
          json.object([
            #("kind", json.String("markdown")),
            #(
              "value",
              json.String(
                "```bea\n"
                <> assist.bea_type(index.signature(entry, Some(qualifier)))
                <> "\n```\n"
                <> entry.doc
                <> case edits {
                  [] -> ""
                  _ -> "\n\n*Adds `import " <> entry.module <> "`*"
                },
              ),
            ),
          ]),
        ),
        #("sortText", json.String(sort <> entry.name)),
        #("filterText", json.String(entry.name)),
        #(
          "textEdit",
          json.object([
            #("range", range_for(new_text)),
            #("newText", json.String(new_text)),
          ]),
        ),
        #("additionalTextEdits", json.Array(edits)),
      ])
      |> callable(new_text)
    })
  json.object([
    #("isIncomplete", json.Bool(truncated)),
    #("items", json.Array(list.append(items, extra))),
  ])
}

const max_unimported = 60

/// Public values of project modules and dependencies that the document
/// doesn't import, whose name matches what is being typed:
/// #(entry, qualifier to write, sort prefix), and whether some were left out.
fn unimported(
  child: Child,
  text: String,
  path: String,
  prefix: String,
  offered: List(String),
) -> #(List(#(index.Entry, String, String)), Bool) {
  let imports = assist.imports(text)
  let imported = dict.values(imports.modules)
  let this = project.module_name(child.project, path)
  let matches = fn(name: String) {
    string.starts_with(name, prefix)
    || { string.length(prefix) >= 3 && string.contains(name, prefix) }
  }
  let bea_modules =
    dict.values(child.modules)
    |> list.map(fn(m) { #(m.name, parser.parse_module(m.source).module) })
  let own = index.project_modules(child.project, bea_modules)
  let candidates = fn(i: index.Index, sort: String) {
    dict.to_list(i)
    |> list.filter(fn(m) { m.0 != this && !list.contains(imported, m.0) })
    |> list.flat_map(fn(m) {
      let qualifier = assist.last_segment(m.0)
      // A different module is imported under that name already, or the name
      // is one of the standard library modules Bea imports by itself.
      let taken =
        dict.has_key(imports.modules, qualifier)
        || list.any(assist.auto_imported, fn(std) {
          std != m.0 && assist.last_segment(std) == qualifier
        })
      case taken {
        True -> []
        False ->
          m.1
          |> list.filter(fn(e) {
            matches(e.name)
            && !list.contains(offered, qualifier <> "." <> e.name)
          })
          |> list.map(fn(e) { #(e, qualifier, sort) })
      }
    })
  }
  let deps = case child.deps_index {
    Some(d) -> candidates(d, "7_")
    None -> []
  }
  let all =
    list.append(candidates(own, "6_"), deps)
    |> list.sort(fn(a, b) {
      case string.compare(a.2, b.2) {
        order.Eq ->
          int.compare(string.length(a.0.name), string.length(b.0.name))
        other -> other
      }
    })
  #(list.take(all, max_unimported), list.length(all) > max_unimported)
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

/// Formatting a Bea document also organises its imports (unless the
/// client turned that off): grouped, sorted, unused ones removed, obvious
/// missing ones added.
fn format(state: State, id: Json, params: Json) -> State {
  let uri = json.string_at(params, ["textDocument", "uri"]) |> option.unwrap("")
  let document =
    position.uri_to_path(uri)
    |> option.then(fn(p) { dict.get(state.docs, p) |> option.from_result })
  case document {
    Some(d) ->
      case string.ends_with(d.path, ".bea") {
        False -> {
          respond(id, json.Null)
          state
        }
        True -> {
          let #(state, source) = case state.organize_imports {
            False -> #(state, d.text)
            True -> {
              let #(state, known) = import_knowledge(state, d.path)
              #(state, imports.organize(d.text, known))
            }
          }
          case formatter.format(source) {
            Ok(formatted) if formatted == d.text -> respond(id, json.Array([]))
            Ok(formatted) -> {
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
            Error(_) -> respond(id, json.Null)
          }
          state
        }
      }
    None -> {
      respond(id, json.Null)
      state
    }
  }
}

/// The project's modules and what every importable module exports.
fn import_knowledge(state: State, path: String) -> #(State, imports.Known) {
  let #(state, key) = ensure_child(state, project_for(path))
  case dict.get(state.children, key) {
    Error(_) -> #(state, imports.nothing_known())
    Ok(child) -> {
      let child = with_deps_index(child)
      let state = put_child(state, child)
      #(
        state,
        imports.for_project(child.project, child.deps_index, path, fn(m) {
          dict.values(child.modules)
          |> list.find(fn(x) { x.name == m })
          |> result.map(fn(x) { x.source })
        }),
      )
    }
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
