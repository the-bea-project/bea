"""Integration test for `bea lsp` against a real project.

Run: python3 test/lsp/test_lsp.py <path-to-bea-project-with-src/app.bea>
The project is created by the test itself when no path is given.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(__file__))
from lsp_client import LspClient, uri  # noqa: E402

FAILURES = []


def check(name, condition, detail=""):
    status = "PASS" if condition else "FAIL"
    print(f"{status} {name}" + ("" if condition else f"\n     {detail}"))
    if not condition:
        FAILURES.append(name)


def position_of(text, needle, offset_in_needle=0, occurrence=0):
    index = -1
    for _ in range(occurrence + 1):
        index = text.index(needle, index + 1)
    index += offset_in_needle
    before = text[:index]
    line = before.count("\n")
    col = len(before) - (before.rfind("\n") + 1)
    return {"line": line, "character": col}


def make_project(root):
    subprocess.run(["bea", "new", "app"], cwd=root, check=True, capture_output=True)
    project = os.path.join(root, "app")
    os.makedirs(os.path.join(project, "src", "app"), exist_ok=True)
    with open(os.path.join(project, "src", "app", "maths.bea"), "w") as f:
        f.write(
            """/// Squares a number.
pub def square(x: Int) -> Int {
  x * x
}

pub type Shape {
  Circle(r: Float)
  Rect(w: Float, h: Float)
}

pub def area(Circle(r)) {
  3.14 *. r *. r
}

pub def area(Rect(w, h)) {
  w *. h
}

pub def pair() -> (Int, String) {
  (1, "one")
}
"""
        )
    with open(os.path.join(project, "src", "app", "helper.gleam"), "w") as f:
        f.write("pub fn twice(x: Int) -> Int {\n  x * 2\n}\n")
    # Not imported by app.bea: completions should offer it and add the import.
    with open(os.path.join(project, "src", "app", "words.bea"), "w") as f:
        f.write(
            """/// Shouts a word.
pub def shout(word: String, times count: Int) -> String {
  string.repeat(string.uppercase(word), count)
}
"""
        )
    # FFI
    with open(os.path.join(project, "src", "app", "native.bea"), "w") as f:
        f.write(
            """@external(erlang, "app_native_ffi", "double")
pub def double(x: Int) -> Int
"""
        )
    with open(os.path.join(project, "src", "app_native_ffi.erl"), "w") as f:
        f.write(
            """-module(app_native_ffi).
-export([double/1]).

%% Doubles a number, natively.
-spec double(integer()) -> integer().
double(X) ->
    X * 2.
"""
        )
    return project


def main():
    tmp = tempfile.mkdtemp(prefix="bea_lsp_test_")
    project = make_project(tmp)
    main_path = os.path.join(project, "src", "app.bea")
    text = """import app/helper
import app/maths.{Circle}
import gleam/io

pub def main() {
  n = maths.square(4)
  shape = Circle(2.0)
  io.println(int.to_string(n + helper.twice(1)))
  echo maths.area(shape)
}
"""
    with open(main_path, "w") as f:
        f.write(text)

    client = LspClient(["bea", "lsp"], cwd=project)
    result = client.initialize(uri(project))
    check("initialize advertises hover", result["capabilities"].get("hoverProvider") is True)

    doc = {"uri": uri(main_path), "languageId": "bea", "version": 1, "text": text}
    client.notify("textDocument/didOpen", {"textDocument": doc})

    # Hover over `square` in `maths.square(4)`
    pos = position_of(text, "maths.square", 7)
    hover = client.request("textDocument/hover", {"textDocument": {"uri": doc["uri"]}, "position": pos})
    contents = json.dumps(hover)
    check("hover shows the signature with parameter names", "maths.square(x: Int) -> Int" in contents, contents)
    check("hover includes doc comment from Bea", "Squares a number" in contents, contents)
    if hover and "range" in hover:
        r = hover["range"]
        check("hover range is in bea coordinates", r["start"]["line"] == pos["line"], json.dumps(r))

    # Tuple types are shown in Bea syntax
    pair_text = text.replace("n = maths.square(4)", "n = maths.square(4)\n  p = maths.pair()")
    client.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc["uri"], "version": 100}, "contentChanges": [{"text": pair_text}]},
    )
    hover = client.request(
        "textDocument/hover",
        {"textDocument": {"uri": doc["uri"]}, "position": position_of(pair_text, "maths.pair", 7)},
    )
    contents = json.dumps(hover)
    check("hover shows tuples in Bea syntax", "(Int, String)" in contents and "#(" not in contents, contents)
    client.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc["uri"], "version": 101}, "contentChanges": [{"text": text}]},
    )

    # Go to definition of `square` -> maths.bea
    definition = client.request("textDocument/definition", {"textDocument": {"uri": doc["uri"]}, "position": pos})
    d = json.dumps(definition)
    check("definition points into maths.bea", "maths.bea" in d, d)
    if isinstance(definition, dict) or (isinstance(definition, list) and definition):
        loc = definition if isinstance(definition, dict) else definition[0]
        target = loc.get("range") or loc.get("targetRange")
        check("definition range is line 1 of maths.bea", target["start"]["line"] == 1, json.dumps(loc))

    # Definition into the hand written Gleam module maps to src/, not .beabuild
    pos2 = position_of(text, "helper.twice", 7)
    definition = client.request("textDocument/definition", {"textDocument": {"uri": doc["uri"]}, "position": pos2})
    d = json.dumps(definition)
    check("definition into .gleam module maps to src/", "/src/app/helper.gleam" in d and ".beabuild" not in d, d)

    # A type error reported by Gleam, mapped onto the Bea source.
    broken = text.replace("n = maths.square(4)", 'n = maths.square("four")')
    client.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc["uri"], "version": 2}, "contentChanges": [{"text": broken}]},
    )
    params, cursor = client.wait_for_notification(
        "textDocument/publishDiagnostics",
        lambda p: p["uri"] == doc["uri"]
        and any("Type mismatch" in x.get("message", "") for x in p["diagnostics"]),
        timeout=60,
    )
    diag = [x for x in params["diagnostics"] if "Type mismatch" in x.get("message", "")][0]
    expected = position_of(broken, '"four"')
    check(
        "gleam type error mapped to bea position",
        diag["range"]["start"] == expected,
        json.dumps(diag) + " expected " + json.dumps(expected),
    )

    # A Bea syntax error
    syntax = text.replace("n = maths.square(4)", "n = maths.square(4")
    client.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc["uri"], "version": 3}, "contentChanges": [{"text": syntax}]},
    )
    params, cursor = client.wait_for_notification(
        "textDocument/publishDiagnostics",
        lambda p: p["uri"] == doc["uri"] and any(x.get("source") == "bea" for x in p["diagnostics"]),
        timeout=30,
        since=cursor,
    )
    check("bea syntax error is reported", params["diagnostics"][0]["source"] == "bea", json.dumps(params))

    # Completion right after `maths.` while the line doesn't parse yet.
    partial = text.replace("n = maths.square(4)", "n = maths.")
    client.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc["uri"], "version": 4}, "contentChanges": [{"text": partial}]},
    )
    cpos = position_of(partial, "n = maths.", 10)
    items = client.request("textDocument/completion", {"textDocument": {"uri": doc["uri"]}, "position": cpos})
    items = items["items"] if isinstance(items, dict) else (items or [])
    labels = [i["label"] for i in items]
    check("completion after `maths.` offers square", any("square" in l for l in labels), json.dumps(labels[:20]))
    check("completion never offers the placeholder", not any("bea_lsp_hole" in l for l in labels))
    ranges_ok = all(
        i.get("textEdit") is None or i["textEdit"]["range"]["start"]["line"] == cpos["line"] for i in items
    )
    check("completion edit ranges are in bea coordinates", ranges_ok, json.dumps(items[:2]))

    # Completion of a partially typed local name
    client.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc["uri"], "version": 5}, "contentChanges": [{"text": text}]},
    )
    cpos = position_of(text, "maths.area(shape)", len("maths.area(sha"))
    items = client.request("textDocument/completion", {"textDocument": {"uri": doc["uri"]}, "position": cpos})
    items = items["items"] if isinstance(items, dict) else (items or [])
    labels = [i["label"] for i in items]
    check("completion of local variable prefix", "shape" in labels, json.dumps(labels[:30]))

    # References of `n`
    rpos = position_of(text, "n = maths")
    refs = client.request(
        "textDocument/references",
        {"textDocument": {"uri": doc["uri"]}, "position": rpos, "context": {"includeDeclaration": True}},
    )
    check("references of n found twice", refs is not None and len(refs) == 2, json.dumps(refs))

    # Rename `shape`
    rpos = position_of(text, "shape = ")
    prep = client.request("textDocument/prepareRename", {"textDocument": {"uri": doc["uri"]}, "position": rpos})
    check("prepareRename returns a range", prep is not None, json.dumps(prep))
    edit = client.request(
        "textDocument/rename",
        {"textDocument": {"uri": doc["uri"]}, "position": rpos, "newName": "thing"},
    )
    e = json.dumps(edit)
    check("rename edits target the bea file", "app.bea" in e and ".beabuild" not in e and e.count("thing") == 2, e)

    # Formatting (native)
    messy = text.replace("  n = maths.square(4)", "      n   =   maths.square( 4 )")
    client.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc["uri"], "version": 6}, "contentChanges": [{"text": messy}]},
    )
    edits = client.request(
        "textDocument/formatting",
        {"textDocument": {"uri": doc["uri"]}, "options": {"tabSize": 2, "insertSpaces": True}},
    )
    check("formatting returns an edit", edits and edits[0]["newText"] == text, json.dumps(edits)[:300])

    # Document symbols (native)
    client.notify(
        "textDocument/didChange",
        {"textDocument": {"uri": doc["uri"], "version": 7}, "contentChanges": [{"text": text}]},
    )
    maths_text = open(os.path.join(project, "src", "app", "maths.bea")).read()
    maths_doc = {"uri": uri(os.path.join(project, "src", "app", "maths.bea")), "languageId": "bea", "version": 1, "text": maths_text}
    client.notify("textDocument/didOpen", {"textDocument": maths_doc})
    syms = client.request("textDocument/documentSymbol", {"textDocument": {"uri": maths_doc["uri"]}})
    names = [s["name"] for s in syms]
    check("document symbols", names == ["square", "Shape", "area", "pair"], json.dumps(names))

    # Hover inside a multi-clause function (parameters become arg_N in Gleam)
    hpos = position_of(maths_text, "w *. h", 0)
    hover = client.request("textDocument/hover", {"textDocument": {"uri": maths_doc["uri"]}, "position": hpos})
    check("hover inside clause body", "Float" in json.dumps(hover), json.dumps(hover))

    # --- Completion and signature help while typing ---------------------------------
    def edit(new_text, version):
        client.notify(
            "textDocument/didChange",
            {"textDocument": {"uri": doc["uri"], "version": version}, "contentChanges": [{"text": new_text}]},
        )

    def complete(new_text, needle, version, offset=None):
        edit(new_text, version)
        p = position_of(new_text, needle, len(needle) if offset is None else offset)
        res = client.request("textDocument/completion", {"textDocument": {"uri": doc["uri"]}, "position": p})
        return p, (res["items"] if isinstance(res, dict) else (res or []))

    def signature(new_text, needle, version):
        edit(new_text, version)
        p = position_of(new_text, needle, len(needle))
        return client.request("textDocument/signatureHelp", {"textDocument": {"uri": doc["uri"]}, "position": p})

    # Inside an unfinished call (nothing after the cursor closes it).
    typing = text.replace("n = maths.square(4)", "n = int.add(maths.")
    p, items = complete(typing, "int.add(maths.", 20)
    labels = [i["label"] for i in items]
    check("completion inside an unfinished call", any("square" in l for l in labels), json.dumps(labels[:20]))

    # Every edit range is on the cursor's line and ends at the cursor.
    p, items = complete(text, "maths.area(sha", 21)
    bad = [
        i for i in items
        if i.get("textEdit")
        and not (i["textEdit"]["range"]["start"]["line"] == p["line"] == i["textEdit"]["range"]["end"]["line"]
                 and i["textEdit"]["range"]["end"]["character"] == p["character"])
    ]
    check("completion ranges end at the cursor on its line", not bad, json.dumps(bad[:2]))

    # Values of a module that isn't imported, with the import added.
    unimported = text.replace("n = maths.square(4)", "n = sho")
    p, items = complete(unimported, "n = sho", 22)
    shout = [i for i in items if i["label"] == "shout"]
    check("completion offers functions of modules that aren't imported", bool(shout), json.dumps([i["label"] for i in items][:30]))
    if shout:
        item = shout[0]
        check("unimported completion inserts the qualified name", item["textEdit"]["newText"].startswith("words.shout"), json.dumps(item))
        edits = json.dumps(item.get("additionalTextEdits"))
        check("unimported completion adds the import", "import app/words" in edits, edits)
        check("unimported completion has docs", "Shouts a word" in json.dumps(item.get("documentation")), json.dumps(item))

    # Nothing to complete in comments.
    commented = text.replace("n = maths.square(4)", "// maths.\n  n = maths.square(4)")
    p, items = complete(commented, "// maths.", 23)
    check("no completion in comments", items == [], json.dumps(items[:3]))

    # Signature help with parameter names, while the call is unfinished.
    sig = signature(text.replace("n = maths.square(4)", "n = maths.square("), "maths.square(", 24)
    label = sig and sig["signatures"][0]["label"]
    check("signature help in an unfinished call", label == "maths.square(x: Int) -> Int", json.dumps(sig))

    # The argument being typed is tracked, labels included.
    two = text.replace("n = maths.square(4)", 'n = words.shout("a", ').replace("import app/maths.{Circle}", "import app/maths.{Circle}\nimport app/words")
    sig = signature(two, 'words.shout("a", ', 25)
    check("signature help tracks the second argument", sig and sig["activeParameter"] == 1, json.dumps(sig))
    if sig:
        s0 = sig["signatures"][0]
        names = [s0["label"][a:b] for a, b in (x["label"] for x in s0["parameters"])]
        check("signature help shows names and labels", names == ["word: String", "times count: Int"], json.dumps(names))
    sig = signature(text.replace("n = maths.square(4)", 'n = words.shout(times: ').replace("import app/maths.{Circle}", "import app/maths.{Circle}\nimport app/words"), "words.shout(times: ", 26)
    check("signature help follows a labelled argument", sig and sig["activeParameter"] == 1, json.dumps(sig))
    sig = signature(text.replace("n = maths.square(4)", 'n = maths.square(maths.squ'), "maths.square(maths.squ", 27)
    check("signature help while typing an argument", sig and sig["activeParameter"] == 0, json.dumps(sig))
    # A dependency function, with its parameter names from the package source.
    sig = signature(text.replace("n = maths.square(4)", 'n = string.pad_start("a", '), 'string.pad_start("a", ', 28)
    check("signature help for a dependency has parameter names", sig and "desired_length" in sig["signatures"][0]["label"], json.dumps(sig))
    edit(text, 29)

    # --- FFI ------------------------------------------------------------------------
    native_path = os.path.join(project, "src", "app", "native.bea")
    native_text = open(native_path).read()
    native_doc = {"uri": uri(native_path), "languageId": "bea", "version": 1, "text": native_text}
    client.notify("textDocument/didOpen", {"textDocument": native_doc})
    at_external = position_of(native_text, '"double"', 2)
    definition = client.request("textDocument/definition", {"textDocument": {"uri": native_doc["uri"]}, "position": at_external})
    d = json.dumps(definition)
    check("definition of an @external goes to the Erlang function", "app_native_ffi.erl" in d and '"line": 5' in d, d)
    hover = client.request("textDocument/hover", {"textDocument": {"uri": native_doc["uri"]}, "position": at_external})
    h = json.dumps(hover)
    check("hover on an @external shows the Erlang source", "Doubles a number" in h and "X * 2" in h, h)

    client.shutdown()
    stderr = "".join(client.stderr_lines)
    if FAILURES:
        print("\nserver stderr:\n" + stderr[-3000:])
        print(f"\n{len(FAILURES)} check(s) failed")
        sys.exit(1)
    print("\nAll LSP checks passed")
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    main()
