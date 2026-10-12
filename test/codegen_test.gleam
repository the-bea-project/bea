// test/codegen_test.gleam
import bea/codegen
import bea/lexer
import bea/parser
import gleeunit/should

pub fn end_to_end_transpiler_test() {
  // CHANGED: Added 'pub' before 'def'
  let source =
    "
    pub def process(user_id) {
      status = \"active\"
      if status {
        return 40 + 2
      }
    }
  "

  let expected =
    "import gleam/bool\n\npub fn process(user_id) {\n  let status = \"active\"\n  use <- bool.guard(when: status, return: 40 + 2)\n}"

  source
  |> lexer.tokenize()
  |> parser.parse()
  |> codegen.generate()
  |> should.equal(expected)
}

pub fn list_transpiler_test() {
  // CHANGED: Added 'pub' before 'def'
  let source =
    "
    pub def get_roles() {
      roles = [\"admin\", \"user\", \"guest\"]
      return roles
    }
  "

  let expected =
    "pub fn get_roles() {\n  let roles = [\"admin\", \"user\", \"guest\"]\n  roles\n}"

  source
  |> lexer.tokenize()
  |> parser.parse()
  |> codegen.generate()
  |> should.equal(expected)
}
