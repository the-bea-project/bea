#!/usr/bin/env bash
# Compare the trusted compiler (A) with the self-hosted compilers (B, C).
#
# Uses the compilers that scripts/bootstrap.sh left in build/bootstrap/
# (run it first; `--no-install` leaves src/ alone).
#
#   1. Output. A, B and C each compile (`bea transpile`) and format
#      (`bea format --stdin`) every .bea file of the repository: the
#      examples, the fixtures, the test projects, the compiler's own source
#      and the invalid programs of test_projects/invalid. They compile whole
#      projects (`bea transpile --out`: beacode/, test/fixtures/,
#      test_projects/deriving and test_projects/broken), check the
#      formatting of the examples (`bea format --check`), and print their
#      help, version and usage errors. Standard output, standard error, the
#      exit status and the generated Gleam must be the same byte for byte
#      for B and C, and for A and B except for the changes made to the
#      compiler since the seed, which bootstrap/changes-since-seed declares
#      one by one: the self-hosted compilers behave like the trusted one on
#      valid and on invalid programs.
#   2. Behaviour. The Gleam unit tests, scripts/test_examples.sh (which runs
#      the compiled programs and compares what they print),
#      scripts/test_tooling.sh and the language server test run against B
#      and against C.
#
# Usage: scripts/verify_bootstrap.sh [--outputs-only]
set -uo pipefail
export LC_ALL=C NO_COLOR=1

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK="$REPO/build/bootstrap"
OUT="$WORK/verify"
cd "$REPO" || exit 1

suites=1
case ${1:-} in
  --outputs-only) suites=0 ;;
  "") ;;
  *) echo "usage: scripts/verify_bootstrap.sh [--outputs-only]" >&2; exit 2 ;;
esac

declare -A BEA=(
  [A]="$WORK/a/scripts/bea"
  [B]="$WORK/B/gleam/scripts/bea"
  [C]="$WORK/C/gleam/scripts/bea"
)
for s in A B C; do
  [ -x "${BEA[$s]}" ] || { echo "compiler $s is missing: run scripts/bootstrap.sh first" >&2; exit 1; }
done

failures=0
pass() { printf '\033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '\033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }

# The corpus: every Bea file of the repository outside build directories.
mapfile -t files < <(find beacode/src test test_projects compiler/src \
  -name '*.bea' -not -path '*/.beabuild/*' -not -path '*/build/*' | sort)

# record STAGE NAME CMD...: runs CMD (from the repository) and keeps its
# stdout, stderr and exit status under OUT/STAGE/NAME.
record() {
  local stage=$1 name=$2
  shift 2
  local dir="$OUT/$stage/$name"
  mkdir -p "$(dirname "$dir")"
  "$@" >"$dir.out" 2>"$dir.err" </dev/null
  echo $? >"$dir.code"
}

# project STAGE NAME DIR: compiles the Bea project DIR as a whole, keeping
# the diagnostics and the generated Gleam.
project() {
  local stage=$1 name=$2 dir=$3
  local copy="$OUT/$stage/projects/$name"
  rm -rf "$copy" && mkdir -p "$(dirname "$copy")"
  cp -R "$dir" "$copy"
  rm -rf "$copy/.beabuild" "$copy/build"
  (cd "$copy" && "${BEA[$stage]}" transpile --out "$copy.eject") \
    >"$copy.out" 2>"$copy.err" </dev/null
  echo $? >"$copy.code"
  rm -rf "$copy.eject"
  # The `Wrote <dir>` line names the stage's directory.
  sed -i "s|$OUT/$stage/|OUT/|g" "$copy.out" "$copy.err"
  mkdir -p "$copy.gleam"
  [ -d "$copy/.beabuild/src" ] && cp -R "$copy/.beabuild/src" "$copy.gleam/src"
  rm -rf "$copy"
}

echo "Recording what A, B and C do with ${#files[@]} Bea files and 4 projects..."
fixtures_project="$OUT/fixtures_project"
rm -rf "$fixtures_project" && mkdir -p "$fixtures_project/src"
printf 'name = "fixtures"\nversion = "1.0.0"\n\n[dependencies]\ngleam_stdlib = ">= 0.44.0 and < 2.0.0"\n' \
  >"$fixtures_project/bea.toml"
cp test/fixtures/*.bea test/fixtures/*.erl "$fixtures_project/src/"
for stage in A B C; do
  rm -rf "${OUT:?}/$stage"
  bea=${BEA[$stage]}
  for f in "${files[@]}"; do
    record "$stage" "transpile/$f" "$bea" transpile "$f"
    record "$stage" "format/$f" sh -c '"$1" format --stdin < "$2"' _ "$bea" "$f"
  done
  record "$stage" cli/help "$bea" --help
  record "$stage" cli/version "$bea" --version
  record "$stage" cli/run-help "$bea" run --help
  record "$stage" cli/transpile-usage "$bea" transpile
  record "$stage" cli/unknown-command "$bea" frobnicate
  record "$stage" cli/format-check-examples "$bea" format --check beacode/src test/fixtures
  record "$stage" cli/format-check-unformatted "$bea" format --check test_projects/invalid/unformatted.bea
  record "$stage" cli/transpile-missing "$bea" transpile does/not/exist.bea
  record "$stage" cli/pack-help "$bea" pack --help
  record "$stage" cli/pack-unknown-option "$bea" pack --frob
  project "$stage" beacode beacode
  project "$stage" fixtures "$fixtures_project"
  project "$stage" deriving test_projects/deriving
  project "$stage" broken test_projects/broken
done

compare() {
  local x=$1 y=$2
  if diff -r "$OUT/$x" "$OUT/$y" >"$OUT/$x-vs-$y.diff"; then
    pass "$x and $y: identical output for every file, project and command"
  else
    fail "$x and $y differ (build/bootstrap/verify/$x-vs-$y.diff)"
    head -40 "$OUT/$x-vs-$y.diff"
  fi
}
# A against B: identical except for the changes made to the compiler since
# the seed, each declared in bootstrap/changes-since-seed.
declared=$(grep -v '^#' bootstrap/changes-since-seed | awk 'NF { print $1 }' | sort)
differing=$(cd "$OUT" && diff -rq A B | sed -n 's|^Files A/\([^ ]*\) and B/.*|\1|p; s|^Only in \([AB]\)\(/[^:]*\)\{0,1\}: \(.*\)|\1\2/\3|p' | sort)
undeclared=$(comm -23 <(printf '%s\n' "$differing" | sed '/^$/d') <(printf '%s\n' "$declared"))
stale=$(comm -13 <(printf '%s\n' "$differing" | sed '/^$/d') <(printf '%s\n' "$declared"))
diff -r "$OUT/A" "$OUT/B" >"$OUT/A-vs-B.diff"
if [ -z "$undeclared" ] && [ -z "$stale" ]; then
  pass "A and B: identical output, except the $(printf '%s\n' "$declared" | sed '/^$/d' | wc -l | tr -d ' ') declared changes since the seed"
else
  [ -z "$undeclared" ] || {
    fail "A and B differ beyond the changes declared in bootstrap/changes-since-seed (build/bootstrap/verify/A-vs-B.diff):"
    printf '%s\n' "$undeclared" | sed 's/^/       /'
  }
  [ -z "$stale" ] || {
    fail "declared in bootstrap/changes-since-seed but identical for A and B (remove them):"
    printf '%s\n' "$stale" | sed 's/^/       /'
  }
fi
compare B C

# Sanity: the corpus exercises both successes and failures.
ok=$(find "$OUT/A/transpile" -name '*.code' -exec grep -lx 0 {} + | wc -l)
bad=$(find "$OUT/A/transpile" -name '*.code' -exec grep -Lx 0 {} + | wc -l)
echo "     ($ok files compile, $bad are rejected with diagnostics)"
[ "$bad" -gt 0 ] && [ "$ok" -gt 0 ] || fail "the corpus should have valid and invalid programs"

if [ "$suites" = 1 ]; then
  for stage in B C; do
    bea=${BEA[$stage]}
    pkg="$WORK/$stage/gleam"
    # The unit tests run in the stage's package, against its modules: the
    # compiler built from the Gleam that the previous compiler generated.
    rm -rf "$pkg/test" "$pkg/compiler" "$pkg/beacode" "$pkg/test_projects" "$pkg/bootstrap"
    cp -R test "$pkg/test"
    mkdir -p "$pkg/compiler" && cp -R compiler/src "$pkg/compiler/src"
    cp -R beacode test_projects bootstrap "$pkg/"
    if (cd "$pkg" && gleam test) >"$OUT/$stage-unit.log" 2>&1; then
      pass "$stage: gleam test ($(grep -o '[0-9]* passed' "$OUT/$stage-unit.log" | tail -1))"
    else
      fail "$stage: gleam test"; tail -30 "$OUT/$stage-unit.log"
    fi
    for suite in scripts/test_examples.sh scripts/test_tooling.sh; do
      if BEA="$bea" "$suite" >"$OUT/$stage-$(basename "$suite" .sh).log" 2>&1; then
        pass "$stage: $suite ($(grep -c PASS "$OUT/$stage-$(basename "$suite" .sh).log") checks)"
      else
        fail "$stage: $suite"; grep FAIL "$OUT/$stage-$(basename "$suite" .sh).log" | head -20
      fi
    done
    if PATH="$(dirname "$bea"):$PATH" python3 test/lsp/test_lsp.py >"$OUT/$stage-lsp.log" 2>&1; then
      pass "$stage: test/lsp/test_lsp.py ($(grep -c PASS "$OUT/$stage-lsp.log") checks)"
    else
      fail "$stage: test/lsp/test_lsp.py"; grep FAIL "$OUT/$stage-lsp.log" | head -20
    fi
  done
fi

echo
if [ "$failures" -eq 0 ]; then
  echo "The self-hosted compilers B and C behave like the trusted compiler A"
else
  echo "$failures check(s) failed"
  exit 1
fi
