//// Language server plumbing: framed JSON-RPC over stdio, and child
//// processes (`gleam lsp`) attached through Erlang ports.

import bea/lsp/json.{type Json}
import bea/system
import gleam/bit_array
import gleam/int

pub type Port

pub type Event {
  ClientMessage(BitArray)
  ClientClosed
  ServerData(Port, BitArray)
  ServerExit(Port, Int)
  Timeout
}

/// Put stdio in raw byte mode and start reading client messages.
pub fn start() -> Nil {
  stdio_binary()
  spawn_stdin_reader()
}

@external(erlang, "bea_ffi", "stdio_binary")
fn stdio_binary() -> Nil

@external(erlang, "bea_ffi", "spawn_stdin_reader")
fn spawn_stdin_reader() -> Nil

/// Wait for the next event; a negative timeout waits forever.
@external(erlang, "bea_ffi", "receive_event")
pub fn receive(timeout_ms: Int) -> Event

@external(erlang, "bea_ffi", "write_bytes")
fn write_bytes(data: BitArray) -> Nil

@external(erlang, "bea_ffi", "open_port_process")
pub fn spawn(executable: String, args: List(String), cwd: String) -> Port

@external(erlang, "bea_ffi", "port_send")
fn port_send(port: Port, data: BitArray) -> Bool

@external(erlang, "bea_ffi", "port_close")
pub fn close(port: Port) -> Nil

@external(erlang, "bea_ffi", "split_frames")
pub fn split_frames(buffer: BitArray) -> #(List(BitArray), BitArray)

fn frame(message: Json) -> BitArray {
  let body = bit_array.from_string(json.to_string(message))
  let header =
    "Content-Length: " <> int.to_string(bit_array.byte_size(body)) <> "\r\n\r\n"
  bit_array.append(bit_array.from_string(header), body)
}

/// Send a message to the editor.
pub fn send_client(message: Json) -> Nil {
  write_bytes(frame(message))
}

/// Send a message to a child server.
pub fn send_child(port: Port, message: Json) -> Bool {
  port_send(port, frame(message))
}

pub fn log(message: String) -> Nil {
  system.print_stderr("[bea lsp] " <> message <> "\n")
}
