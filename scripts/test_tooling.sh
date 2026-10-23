#!/usr/bin/env bash
# End-to-end tests for Gleam tooling through the real `bea` CLI:
#
#   1. `bea run` argument handling: entry point selection, `-m` for modules
#      of dependencies (Gleam tools), argument forwarding, `--`, `--help`,
#      stdout/stderr, exit codes, diagnostics.
#   2. Mixed projects: Bea modules importing Gleam modules in src/.
#   3. The generated-code lifecycle: a tool run with `bea run -m` generates a
#      Gleam module into src/, Bea code imports it, regenerating or removing
#      it is picked up, repeated builds leave it alone.
#   4. (opt-in, BEA_TEST_MARMOT=1) The same with the real Marmot and SQLite.
#
# The tool is test_projects/tooling/fixture_tool, a small Gleam package that
# behaves like Marmot (reads [tools.<name>] from gleam.toml, generates code
# into src/generated/sql/). Everything runs under a path with a space in it.
#
# Usage: scripts/test_tooling.sh   (needs `bea` and `gleam` on the PATH, and
#        `node` for the JavaScript test; BEA overrides the bea command)
set -uo pipefail
cd "$(dirname "$0")/.."
REPO=$(pwd)
BEA=${BEA:-bea}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

pass() { printf '\033[32mPASS\033[0m %s\n' "$1"; }
fail() {
  printf '\033[31mFAIL\033[0m %s\n' "$1"
  failures=$((failures + 1))
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /' | head -30
}

# run DIR CMD...: runs a command in DIR; sets $code, $out (stdout), $err.
run() {
  local dir=$1
  shift
  (cd "$dir" && "$@" >"$WORK/out" 2>"$WORK/err" </dev/null)
  code=$?
  out=$(cat "$WORK/out")
  err=$(cat "$WORK/err")
}

# check NAME CONDITION: CONDITION is evaluated with $code/$out/$err set.
check() {
  if eval "$2"; then pass "$1"; else
    fail "$1" "exit: $code
stdout: $out
stderr: $err"
  fi
}

has() { printf '%s' "$1" | grep -qF -- "$2"; }

ROOT="$WORK/with space"
TOOL="$ROOT/fixture tool"
APP="$ROOT/example app"
mkdir -p "$ROOT"
cp -r test_projects/tooling/fixture_tool "$TOOL"
cp -r test_projects/tooling/example "$APP"
rm -rf "$TOOL/build" "$APP/.beabuild" "$APP/manifest.toml"
# Path dependencies are resolved from the generated project in .beabuild/,
# so use an absolute path.
sed "s|@FIXTURE_TOOL@|$TOOL|" test_projects/tooling/example/bea.toml >"$APP/bea.toml"

# --- 1. bea run ------------------------------------------------------------------

run "$APP" $BEA build --warnings-as-errors
check "mixed project builds without warnings" '[ $code -eq 0 ]'

run "$APP" $BEA run
check "bea run runs the project's main" \
  '[ $code -eq 0 ] && [ "$out" = "example: no arguments" ]'

run "$APP" $BEA run one "two words" --three
check "bea run passes arguments to the program" \
  '[ $code -eq 0 ] && [ "$out" = "example: [one] [two words] [--three]" ]'

run "$APP" $BEA run -- --flag
check "bea run -- passes flags to the program" \
  '[ $code -eq 0 ] && [ "$out" = "example: [--flag]" ]'

run "$APP" $BEA run --help
check "bea run --help shows bea's help without building" \
  '[ $code -eq 0 ] && has "$out" "Usage: bea run" && ! has "$err" "Compil"'

run "$APP" $BEA run -m fixture_tool --help
check "bea run -m TOOL --help is bea's help, not gleam build's" \
  '[ $code -eq 0 ] && has "$out" "Usage: bea run" && ! has "$out" "gleam build"'

run "$APP" $BEA run -m fixture_tool help
check "bea run -m TOOL help runs the tool's help" \
  '[ $code -eq 0 ] && has "$out" "fixture_tool help"'

run "$APP" $BEA run -m fixture_tool echo "a b" --flag -- "" x
check "tool gets its arguments unchanged (flags, --, spaces, empty)" \
  '[ $code -eq 0 ] && [ "$out" = "[a b] [--flag] [--] [] [x]" ]'
check "tool stdout and stderr are kept apart" \
  'has "$err" "echo: done" && ! has "$out" "echo: done"'

run "$APP" $BEA run -m fixture_tool -- echo --only
check "bea run -m TOOL -- ARGS" '[ $code -eq 0 ] && [ "$out" = "[--only]" ]'

run "$APP" $BEA run -m fixture_tool fail 3
check "tool exit code is preserved" \
  '[ $code -eq 3 ] && has "$err" "failing with 3"'

run "$APP" $BEA run -m fixture_tool unknown
check "tool errors are passed through" \
  '[ $code -eq 2 ] && has "$err" "unknown command unknown"'

run "$APP" $BEA run -m fixture_tool --greeting x
check "options of the program before -- are an error, not a build flag" \
  '[ $code -eq 1 ] && has "$err" "Unknown option \`--greeting\`" && has "$err" "bea run -m fixture_tool -- --greeting x"'

run "$APP" $BEA run -m no_such_module
check "unknown module: useful diagnostic" \
  '[ $code -eq 1 ] && has "$err" "Module \`no_such_module\` was not found" && ! has "$err" "undef"'

run "$APP" $BEA run -m fixture_tool/no_main
check "module without main: useful diagnostic" \
  '[ $code -eq 1 ] && has "$err" "does not have a public \`main\` function"'

run "$APP" $BEA run -m "Bad Name"
check "invalid module name is rejected before building" \
  '[ $code -eq 1 ] && has "$err" "not a valid module name" && ! has "$err" "Compil"'

run "$APP" $BEA run -m fixture_tool config
check "tool reads [tools.*] from bea.toml (as gleam.toml)" \
  '[ $code -eq 0 ] && [ "$out" = "greeting from gleam.toml: Bonjour" ]'
check "no gleam.toml is left in the project" '[ ! -e "$APP/gleam.toml" ] && [ ! -L "$APP/gleam.toml" ]'

printf '[tools.fixture_tool]\ngreeting = "Own"\n' >"$APP/gleam.toml"
run "$APP" $BEA run -m fixture_tool config
check "an existing gleam.toml is used and left alone" \
  '[ "$out" = "greeting from gleam.toml: Own" ] && [ "$(cat "$APP/gleam.toml")" = "$(printf "[tools.fixture_tool]\ngreeting = \"Own\"")" ]'
rm "$APP/gleam.toml"

run "$APP" $BEA run -m example/main
check "Bea module calls the Gleam module in src/generated/sql" \
  '[ $code -eq 0 ] && [ "$out" = "$(printf "Hello from dev.sqlite\nid 1\nno greeting 2")" ]'

printf 'pub def broken() -> Int {\n  "not an int"\n}\n' >"$APP/src/example/broken.bea"
run "$APP" $BEA run -m fixture_tool echo ran
check "compile errors prevent running a tool" \
  '[ $code -ne 0 ] && ! has "$out" "[ran]" && has "$err" "src/example/broken.bea"'
rm "$APP/src/example/broken.bea"

if command -v node >/dev/null 2>&1; then
  run "$APP" $BEA run --target javascript -m fixture_tool echo "on node"
  check "tool from a dependency on the JavaScript target" \
    '[ $code -eq 0 ] && [ "$out" = "[on node]" ]'
  run "$APP" $BEA run --target javascript -m example/main
  check "mixed project on the JavaScript target" \
    '[ $code -eq 0 ] && has "$out" "Hello from dev.sqlite"'
fi

mkdir -p "$ROOT/script dir"
printf 'pub def main() {\n  io.println("hello from a script")\n}\n' >"$ROOT/script dir/hello.bea"
run "$ROOT" $BEA run "script dir/hello.bea"
check "bea run FILE.bea outside a project still works" \
  '[ $code -eq 0 ] && [ "$out" = "hello from a script" ]'

# --- 2/3. Generated code lifecycle ---------------------------------------------------

LIFE="$ROOT/life cycle"
cp -r "$APP" "$LIFE"
rm -rf "$LIFE/.beabuild" "$LIFE/src/generated"
mv "$LIFE/src/example/main.bea" "$WORK/main.bea"
GEN="$LIFE/src/generated/sql/example_sql.gleam"

run "$LIFE" $BEA build
check "lifecycle: project builds before anything is generated" '[ $code -eq 0 ]'

run "$LIFE" $BEA run -m fixture_tool -- --greeting Hola
check "lifecycle: bea run -m TOOL -- FLAGS generates into src/" \
  '[ $code -eq 0 ] && has "$out" "wrote src/generated/sql/example_sql.gleam" && [ -f "$GEN" ]'

cp "$WORK/main.bea" "$LIFE/src/example/main.bea"
run "$LIFE" $BEA build --warnings-as-errors
check "lifecycle: Bea imports the generated module" '[ $code -eq 0 ]'
run "$LIFE" $BEA run -m example/main
check "lifecycle: and runs" '[ $code -eq 0 ] && has "$out" "Hola from dev.sqlite"'

before=$(cksum <"$GEN")
run "$LIFE" $BEA build
run "$LIFE" $BEA build
run "$LIFE" $BEA run -m example/main
check "lifecycle: generated file survives repeated builds" \
  '[ -f "$GEN" ] && [ "$(cksum <"$GEN")" = "$before" ] && has "$out" "Hola"'

run "$LIFE" $BEA run -m fixture_tool -- --greeting Ciao
run "$LIFE" $BEA run -m example/main
check "lifecycle: regenerated module is used (no stale build)" \
  '[ $code -eq 0 ] && has "$out" "Ciao from dev.sqlite"'

run "$LIFE" $BEA run -m fixture_tool
run "$LIFE" $BEA run -m example/main
check "lifecycle: tool configured from bea.toml" \
  '[ $code -eq 0 ] && has "$out" "Bonjour from dev.sqlite"'

rm "$GEN"
run "$LIFE" $BEA run -m example/main
check "lifecycle: removed module is gone from the build too" \
  '[ $code -ne 0 ] && has "$err" "generated/sql/example_sql" && ! has "$out" "Bonjour"'

rm "$LIFE/src/example/main.bea"
run "$LIFE" $BEA clean
run "$LIFE" $BEA run -m fixture_tool -- --greeting Again
check "lifecycle: tool runs from a clean build directory" \
  '[ $code -eq 0 ] && [ -f "$GEN" ]'
cp "$WORK/main.bea" "$LIFE/src/example/main.bea"
run "$LIFE" $BEA run -m example/main
check "lifecycle: from a clean build directory" \
  '[ $code -eq 0 ] && has "$out" "Again from dev.sqlite"'

# --- 4. Marmot (opt-in) ------------------------------------------------------------

if [ "${BEA_TEST_MARMOT:-}" = "1" ]; then
  # Needs network access to Hex and a C compiler (sqlight's esqlite builds
  # SQLite as a NIF).
  M="$ROOT/marmot app"
  (cd "$ROOT" && $BEA new marmot_app >/dev/null && mv marmot_app "$M")
  (cd "$M" && $BEA add sqlight >/dev/null 2>&1 && $BEA add --dev marmot >/dev/null 2>&1)
  mkdir -p "$M/db/migrations" "$M/src/marmot_app/users/sql"
  printf 'create table users (id integer primary key, name text not null);\n' \
    >"$M/db/migrations/001_create_users.sql"
  printf 'select id, name from users where name = ?\n' >"$M/src/marmot_app/users/sql/find_user.sql"
  printf 'insert into users (name) values (?)\n' >"$M/src/marmot_app/users/sql/add_user.sql"
  printf '\n[tools.marmot]\ndatabase = "dev.sqlite"\n' >>"$M/bea.toml"

  run "$M" $BEA run -m marmot migrate --database dev.sqlite
  check "marmot: bea run -m marmot migrate --database dev.sqlite" \
    '[ $code -eq 0 ] && has "$out" "Applied 001_create_users" && [ -f "$M/dev.sqlite" ]'
  run "$M" $BEA run -m marmot -- --database dev.sqlite
  check "marmot: bea run -m marmot -- --database dev.sqlite" \
    '[ $code -eq 0 ] && [ -f "$M/src/generated/sql/marmot_app/users_sql.gleam" ]'
  cat >"$M/src/marmot_app.bea" <<'EOF'
import generated/sql/marmot_app/users_sql.{FindUserRow}
import sqlight

pub def main() {
  use db <- sqlight.with_connection("dev.sqlite")
  Ok(_) = users_sql.add_user(db:, name: "bea") else panic
  Ok([FindUserRow(id:, name:)]) = users_sql.find_user(db:, name: "bea")
    else panic
  io.println("#{int.to_string(id)}: #{name}")
}
EOF
  run "$M" $BEA run
  check "marmot: bea run uses the generated module" \
    '[ $code -eq 0 ] && [ "$out" = "1: bea" ]'
  run "$M" $BEA run -m marmot
  check "marmot: configured from [tools.marmot] in bea.toml" '[ $code -eq 0 ]'
else
  echo "SKIP marmot tests (set BEA_TEST_MARMOT=1; they need Hex and a C compiler)"
fi

echo
if [ "$failures" -eq 0 ]; then echo "All tooling tests passed"; else echo "$failures test(s) failed"; exit 1; fi
