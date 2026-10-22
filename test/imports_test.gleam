import bea/imports.{Known}
import gleam/dict
import gleam/set
import gleeunit/should

fn known() -> imports.Known {
  Known(
    internal: set.from_list([
      "beahive/context", "beahive_web/utils", "beahive_web/middleware",
    ]),
    exports: dict.from_list([
      #(
        "gleam/http/request",
        set.from_list(["new", "path_segments", "Request"]),
      ),
      #("wisp/request", set.from_list(["new"])),
      #("gleam/erlang/process", set.from_list(["sleep_forever", "sleep"])),
      #("sqlight", set.from_list(["open", "exec"])),
      #("beahive/config", set.from_list(["load"])),
    ]),
    current: "beahive_web/router",
  )
}

pub fn groups_and_sorts_test() {
  "// router

import ewe
import gleam/http
import gleam/json
import gleam/time/timestamp
import gleam/http/request
import gleam/http/response.{type Response}

import beahive/context.{type Context}
import beahive_web/utils
import beahive_web/middleware as global_middleware

pub def handle(req: request.Request(ewe.Connection), ctx: Context) -> Response(ewe.Body) {
  use <- global_middleware.apply(req, ctx)
  _ = timestamp.system_time()
  case req.method {
    http.Get -> utils.send(json.null())
    _ -> utils.send(json.null())
  }
}
"
  |> imports.organize(known())
  |> should.equal(
    "// router

import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/json
import gleam/time/timestamp

import ewe

import beahive/context.{type Context}
import beahive_web/middleware as global_middleware
import beahive_web/utils

pub def handle(req: request.Request(ewe.Connection), ctx: Context) -> Response(ewe.Body) {
  use <- global_middleware.apply(req, ctx)
  _ = timestamp.system_time()
  case req.method {
    http.Get -> utils.send(json.null())
    _ -> utils.send(json.null())
  }
}
",
  )
}

pub fn removes_unused_test() {
  "import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/time/duration

pub def f(x: Option(Int)) {
  case x {
    Some(n) -> n
    _ -> 0
  }
}
"
  |> imports.organize(known())
  |> should.equal(
    "import gleam/option.{type Option, Some}

pub def f(x: Option(Int)) {
  case x {
    Some(n) -> n
    _ -> 0
  }
}
",
  )
}

pub fn shadowed_module_name_is_not_a_use_test() {
  "import gleam/http/request

pub def f(request) {
  request.path
}
"
  |> imports.organize(known())
  |> should.equal(
    "pub def f(request) {
  request.path
}
",
  )
}

pub fn adds_obvious_imports_test() {
  "import gleam/io

pub def main() {
  db = sqlight.open(\"x\")
  io.println(\"hi\")
  list.map([], fn(x) { x })
  process.sleep_forever()
}
"
  |> imports.organize(known())
  |> should.equal(
    "import gleam/erlang/process
import gleam/io

import sqlight

pub def main() {
  db = sqlight.open(\"x\")
  io.println(\"hi\")
  list.map([], fn(x) { x })
  process.sleep_forever()
}
",
  )
}

pub fn ambiguous_or_unknown_member_is_not_added_test() {
  // Two modules are called `request`, and `sqlight` has no `close`.
  let source =
    "pub def main() {
  request.new()
  sqlight.close()
}
"
  source
  |> imports.organize(known())
  |> should.equal(source)
}

pub fn member_check_picks_the_right_module_test() {
  "pub def main() {
  request.path_segments(r)
}
"
  |> imports.organize(known())
  |> should.equal(
    "import gleam/http/request

pub def main() {
  request.path_segments(r)
}
",
  )
}

pub fn comments_move_with_imports_test() {
  "import sqlight
// time things
import gleam/time/timestamp // wall clock

pub def f() {
  sqlight.open(timestamp.system_time())
}
"
  |> imports.organize(known())
  |> should.equal(
    "// time things
import gleam/time/timestamp // wall clock

import sqlight

pub def f() {
  sqlight.open(timestamp.system_time())
}
",
  )
}

pub fn stray_imports_join_the_block_test() {
  "import sqlight

pub def f() {
  sqlight.open(json.null())
}

import gleam/json
"
  |> imports.organize(known())
  |> should.equal(
    "import gleam/json

import sqlight

pub def f() {
  sqlight.open(json.null())
}

",
  )
}

pub fn first_import_goes_after_module_doc_test() {
  "//// A module.

pub def f() {
  config.load()
}
"
  |> imports.organize(known())
  |> should.equal(
    "//// A module.

import beahive/config

pub def f() {
  config.load()
}
",
  )
}

pub fn label_shorthand_and_unqualified_values_test() {
  let source =
    "import gleam/list.{map}

pub def f(xs) {
  Box(map:, xs:)
}
"
  source
  |> imports.organize(imports.nothing_known())
  |> should.equal(source)
}

pub fn idempotent_and_broken_code_untouched_test() {
  let once =
    "import gleam/json
import ewe

pub def f() { ewe.x(json.null()) }
"
    |> imports.organize(known())
  once |> imports.organize(known()) |> should.equal(once)
  let broken = "import ewe\nimport gleam/json\n\npub def f( {\n"
  broken |> imports.organize(known()) |> should.equal(broken)
}
