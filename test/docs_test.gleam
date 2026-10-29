import bea/docs
import bea/parser
import gleam/string
import gleam/list
import gleeunit/should

pub fn public_api_only_test() {
  let source = "//// Sample module.\n/// Public function.\npub def hello(name: String) -> String { name }\ndef hidden() { 1 }\n/// Public record.\npub type User { name: String }\n"
  let parsed = parser.parse_module(source)
  parsed.errors |> should.equal([])
  let page = docs.extract("example", parsed.module)
  string.contains(page.documentation, "Sample module") |> should.equal(True)
  page.entries |> list.length |> should.equal(2)
  let html = docs.render(page)
  string.contains(html, "hello") |> should.equal(True)
  string.contains(html, "User") |> should.equal(True)
  string.contains(html, ">hidden</a>") |> should.equal(False)
}

pub fn escaping_test() {
  docs.escape_html("<script>alert('x') & \"hello\"</script>")
  |> should.equal("&lt;script&gt;alert(&#39;x&#39;) &amp; &quot;hello&quot;&lt;/script&gt;")
}

pub fn navigation_and_search_test() {
  let page = docs.Page("bea_codecs/json/decoder", "Decode **JSON**", [
    docs.Entry("from_json", "pub def from_json(text: String)", "Parse JSON text"),
  ])
  let html = docs.render(page)
  string.contains(html, "docs-search") |> should.equal(True)
  string.contains(html, "module-group") |> should.equal(True)
  string.contains(html, "from_json") |> should.equal(True)
  string.contains(html, "assets/beatrix.svg") |> should.equal(True)
  string.contains(html, "assets/docs.js") |> should.equal(True)
  string.contains(html, "markdown-source") |> should.equal(True)
  string.contains(html, "wrap-toggle") |> should.equal(True)
}

pub fn index_links_nested_modules_test() {
  let page = docs.Page("bea_codecs/json/encoder", "Serialize", [])
  let html = docs.index([page], "bea_codecs")
  string.contains(html, "modules/bea_codecs/json/encoder.html") |> should.equal(True)
  string.contains(html, "assets/docs.css") |> should.equal(True)
}
