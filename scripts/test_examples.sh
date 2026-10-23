#!/usr/bin/env bash
# End-to-end tests through the real `bea` CLI.
#
#   1. Every program in test/fixtures/ is run and its stdout compared with the
#      matching .expected file.
#   2. Every exercism program in beacode/ must build and run.
#   3. Formatting every .bea file must succeed and be idempotent.
#   4. test_projects/deriving (`@derive` with JSON and form derivers) builds
#      without warnings and its output matches, on Erlang and JavaScript.
#
# Usage: scripts/test_examples.sh   (needs `bea` and `gleam` on the PATH;
#        BEA overrides the bea command, e.g. BEA="gleam run --")
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)
BEA=${BEA:-bea}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '\033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }

# --- 1. fixtures with expected output -------------------------------------------
(cd "$WORK" && $BEA new fixtures >/dev/null)
cp test/fixtures/*.bea test/fixtures/*.erl "$WORK/fixtures/src/" 2>/dev/null
rm -f "$WORK/fixtures/src/fixtures.bea"
(cd "$WORK/fixtures" && $BEA add simplifile >/dev/null 2>&1)
if (cd "$WORK/fixtures" && $BEA build >"$WORK/build.log" 2>&1); then
  pass "fixtures project builds"
else
  fail "fixtures project builds"; cat "$WORK/build.log"
fi
for f in test/fixtures/*.bea; do
  name=$(basename "$f" .bea)
  actual=$(cd "$WORK/fixtures" && $BEA run -m "$name" 2>/dev/null)
  if diff <(echo "$actual") "test/fixtures/$name.expected" >"$WORK/diff" 2>&1; then
    pass "fixture $name"
  else
    fail "fixture $name"; head -20 "$WORK/diff"
  fi
done

# --- 2. exercism examples ----------------------------------------------------------
cp -r beacode "$WORK/beacode"
for f in "$WORK"/beacode/src/*.bea; do
  name=$(basename "$f" .bea)
  # Library-style exercises have no `main`: building them is the test.
  grep -q "^pub def main" "$f" || { (cd "$WORK/beacode" && $BEA build >"$WORK/run.log" 2>&1) && pass "example $name (build)" || { fail "example $name"; tail -20 "$WORK/run.log"; }; continue; }
  if (cd "$WORK/beacode" && $BEA run -m "$name" </dev/null >"$WORK/run.log" 2>&1); then
    pass "example $name"
  else
    fail "example $name"; tail -20 "$WORK/run.log"
  fi
done

# --- 3. formatter -------------------------------------------------------------
mkdir -p "$WORK/format"
cp beacode/src/*.bea test/fixtures/*.bea "$WORK/format/"
if $BEA format "$WORK/format" >"$WORK/format.log" 2>&1; then
  pass "format all files"
else
  fail "format all files"; cat "$WORK/format.log"
fi
if $BEA format --check "$WORK/format" >"$WORK/format.log" 2>&1; then
  pass "format is idempotent"
else
  fail "format is idempotent"; cat "$WORK/format.log"
fi
# Formatted fixtures must still behave the same.
cp "$WORK"/format/*.bea "$WORK/fixtures/src/" && rm -f "$WORK"/fixtures/src/e[0-9]*.bea
for f in test/fixtures/*.bea; do
  name=$(basename "$f" .bea)
  actual=$(cd "$WORK/fixtures" && $BEA run -m "$name" 2>/dev/null)
  if diff <(echo "$actual") "test/fixtures/$name.expected" >/dev/null 2>&1; then
    pass "formatted fixture $name"
  else
    fail "formatted fixture $name"
  fi
done

# --- 4. @derive ------------------------------------------------------------------
cp -r test_projects/deriving "$WORK/deriving"
rm -rf "$WORK/deriving/.beabuild" "$WORK/deriving/manifest.toml"
if (cd "$WORK/deriving" && $BEA build --warnings-as-errors >"$WORK/build.log" 2>&1); then
  pass "deriving project builds without warnings"
else
  fail "deriving project builds without warnings"; cat "$WORK/build.log"
fi
actual=$(cd "$WORK/deriving" && $BEA run 2>/dev/null)
if diff <(echo "$actual") test_projects/deriving/expected_erlang.txt >"$WORK/diff" 2>&1; then
  pass "deriving project (Erlang)"
else
  fail "deriving project (Erlang)"; head -20 "$WORK/diff"
fi
if command -v node >/dev/null 2>&1; then
  actual=$(cd "$WORK/deriving" && $BEA run --target javascript 2>/dev/null)
  if diff <(echo "$actual") test_projects/deriving/expected_javascript.txt >"$WORK/diff" 2>&1; then
    pass "deriving project (JavaScript)"
  else
    fail "deriving project (JavaScript)"; head -20 "$WORK/diff"
  fi
fi
if $BEA format --check "$WORK/deriving/src" >"$WORK/format.log" 2>&1; then
  pass "deriving project is formatted"
else
  fail "deriving project is formatted"; cat "$WORK/format.log"
fi

echo
if [ "$failures" -eq 0 ]; then echo "All end-to-end tests passed"; else echo "$failures test(s) failed"; exit 1; fi
