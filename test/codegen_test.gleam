// test/codegen_test.gleam
import bea/codegen
import bea/lexer
import bea/parser
import gleeunit/should

pub fn end_to_end_transpiler_test() {
  let source =
    "def process(user_id) {
  status = \"active\"
  if status {
    return 40 + 2
  }
}"

  let output =
    source
    |> lexer.tokenize()
    |> parser.parse()
    |> codegen.generate()

  let expected =
    "import gleam/bool

pub fn process(user_id) {
  let status = \"active\"
  use <- bool.guard(when: status, return: 40 + 2)
}"

  output |> should.equal(expected)
}

pub fn list_transpiler_test() {
  let source =
    "def get_roles() {
  roles = [\"admin\", \"user\", \"guest\"]
  return roles
}"

  let output =
    source
    |> lexer.tokenize()
    |> parser.parse()
    |> codegen.generate()

  let expected =
    "pub fn get_roles() {
  let roles = [\"admin\", \"user\", \"guest\"]
  roles
}"

  output |> should.equal(expected)
}
