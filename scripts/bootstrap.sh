#!/usr/bin/env bash
# Build the Bea compiler from its Bea sources, starting from a trusted seed.
#
#   A  The trusted seed: the last revision of the compiler written entirely
#      in Gleam, pinned by its git tree in bootstrap/seed.env. It is
#      extracted from git into build/bootstrap/a and built with Gleam.
#   B  compiler/src compiled to Gleam by A, then built with Gleam.
#   C  compiler/src compiled to Gleam by B, then built with Gleam.
#
# The Gleam that A and B generate from compiler/src must be identical, byte
# for byte: B, written in Bea, compiles its own source exactly like the
# trusted compiler, and C is built from the same code as B. That Gleam is
# then installed into src/ (generated, ignored by git) and the repository is
# built, so `gleam test`, scripts/bea and the other scripts use it.
#
# Usage: scripts/bootstrap.sh [options]
#   --quick       Instead of A, B and C: compile compiler/src with the
#                 compiler this checkout has built (scripts/bea), install
#                 the result and build it. For working on the compiler; run
#                 it twice when a change affects the compiler's own output,
#                 and the full bootstrap before committing.
#   --seed REV    Build compiler A from REV (a commit, tag or tree of an
#                 all-Gleam revision, with the compiler in src/) instead of
#                 the pinned seed.
#   --via REV     Compile REV's compiler/src with the compiler so far and
#                 use the result as the next compiler (repeatable). This
#                 continues the chain of trust once compiler/src uses
#                 something the seed can't compile: seed -> REV -> B -> C.
#                 Revisions in SEED_VIA (bootstrap/seed.env) are used the
#                 same way when no --via is given.
#   --no-install  Stop after building and comparing B and C; leave src/ and
#                 the repository's build alone.
#   --force       Install even over files in src/ that the bootstrap didn't
#                 write or that were edited after it wrote them.
#
# Needs git (with the seed in its history, so not a shallow clone), Gleam
# and Erlang/OTP; see docs/self-hosting.md. Works in build/bootstrap/.
set -euo pipefail
export LC_ALL=C

REPO=$(cd "$(dirname "$0")/.." && pwd)
WORK="$REPO/build/bootstrap"
# shellcheck source=../bootstrap/seed.env
. "$REPO/bootstrap/seed.env"

quick=0
install=1
force=0
seed_rev=""
via=()
while [ $# -gt 0 ]; do
  case $1 in
    --quick) quick=1 ;;
    --no-install) install=0 ;;
    --force) force=1 ;;
    --seed) seed_rev=${2:?--seed needs a revision}; shift ;;
    --via) via+=("${2:?--via needs a revision}"); shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    *) echo "bootstrap: unknown option $1 (see --help)" >&2; exit 2 ;;
  esac
  shift
done

step() { printf '\033[1;35m%-8s\033[0m %s\n' "$1" "$2"; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$1" >&2; exit 1; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi
}

# compile_sources BEA FROM OUT: compiles FROM/compiler/src (FROM also has
# the gleam.toml and manifest.toml) as one Bea project with the bea command
# BEA, and writes the generated Gleam package to OUT/gleam. Its modules are
# the compiler's raw output (what `bea build` compiles), so comparing two of
# them compares the compilers and nothing else.
compile_sources() {
  local bea=$1 from=$2 out=$3
  rm -rf "$out"
  mkdir -p "$out/project"
  cp "$from/gleam.toml" "$out/project/bea.toml"
  cp "$from/manifest.toml" "$out/project/manifest.toml"
  cp -R "$from/compiler/src" "$out/project/src"
  if ! (cd "$out/project" && NO_COLOR=1 "$bea" transpile --out "$out/eject") \
    >"$out/compile.log" 2>&1; then
    cat "$out/compile.log" >&2
    die "compiling ${from#"$REPO"/}/compiler/src failed"
  fi
  mkdir -p "$out/gleam/scripts"
  cp "$out/project/.beabuild/gleam.toml" "$out/project/.beabuild/manifest.toml" "$out/gleam/"
  cp -R "$out/project/.beabuild/src" "$out/gleam/src"
  cp "$REPO/scripts/bea" "$out/gleam/scripts/bea"
  rm -rf "$out/eject"
}

# build_package DIR LOG [FLAGS]: `gleam build` in DIR, logged to LOG.
build_package() {
  local dir=$1 log=$2
  shift 2
  if ! (cd "$dir" && gleam build "$@") >"$log" 2>&1; then
    cat "$log" >&2
    die "building ${dir#"$REPO"/} failed (log: ${log#"$REPO"/})"
  fi
}

compiler=""      # the bea command of the current stage
compiler_name="" # what to call it
generated=""     # the Gleam the last stage generated from compiler/src

# stage_a: extracts the seed from git and builds it.
stage_a() {
  local rev=${seed_rev:-$SEED_TREE} tree dir="$WORK/a"
  tree=$(git -C "$REPO" rev-parse --verify --quiet "$rev^{tree}") ||
    die "the seed $rev isn't in this repository's history.
  Compiler A is built from git history: clone without --depth, or run
  \`git fetch --unshallow\` in a shallow clone."
  if [ -z "$seed_rev" ]; then
    step "A" "trusted seed, tree $SEED_TREE"
    step "" "($SEED_SUBJECT)"
  else
    step "A" "seed $seed_rev (tree $tree), not the pinned one"
  fi
  if [ "$(cat "$dir/.seed-tree" 2>/dev/null || true)" != "$tree" ]; then
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$REPO" archive "$tree" | tar -x -C "$dir"
    [ -f "$dir/src/bea.gleam" ] ||
      die "$rev is not an all-Gleam revision (it has no src/bea.gleam); see --via"
  fi
  build_package "$dir" "$WORK/a.log"
  echo "$tree" >"$dir/.seed-tree"
  compiler="$dir/scripts/bea"
  compiler_name="compiler A"
}

# stage NAME FROM: compiles FROM's compiler/src with the current compiler,
# builds the result and makes it the current compiler.
stage() {
  local name=$1 from=$2
  local label=${from#"$REPO"}
  step "$name" "compiler/src${label:+ of ${label#/}} compiled by $compiler_name"
  compile_sources "$compiler" "$from" "$WORK/$name"
  build_package "$WORK/$name/gleam" "$WORK/$name/build.log" --warnings-as-errors
  compiler="$WORK/$name/gleam/scripts/bea"
  compiler_name="compiler $name"
  generated="$WORK/$name/gleam/src"
}

# install_sources FROM: makes src/ a copy of FROM, refusing to overwrite
# anything the bootstrap didn't write itself.
install_sources() {
  local from=$1 dest="$REPO/src" manifest="$REPO/src/.bea-generated"
  if [ -n "$(git -C "$REPO" ls-files -- src)" ]; then
    die "src/ has files tracked by git, but src/ is generated: the
  compiler's sources live in compiler/src."
  fi
  if [ -d "$dest" ] && [ "$force" = 0 ]; then
    if [ ! -f "$manifest" ]; then
      [ -z "$(ls -A "$dest")" ] ||
        die "src/ exists but wasn't written by the bootstrap (there is no
  src/.bea-generated), and it is about to be replaced with generated code.
  The compiler's sources live in compiler/src: move anything you need there,
  then delete src/ (or pass --force)."
    else
      local changed extra
      changed=$(cd "$dest" && grep -v '^#' .bea-generated | sha256 -c 2>/dev/null |
        grep -v ': OK$' | sed 's/: FAILED.*//' || true)
      [ -z "$changed" ] ||
        die "files in src/ were changed after the bootstrap generated them:
$(printf '%s\n' "$changed" | sed 's/^/    /')
  The bootstrap would overwrite them. Make the change in compiler/src instead
  (or pass --force to discard it)."
      extra=$(cd "$dest" && find . -type f ! -name .bea-generated | sort |
        comm -23 - <(grep -v '^#' .bea-generated | sed 's/^[0-9a-f]* [ *]//' | sort))
      [ -z "$extra" ] ||
        die "src/ has files the bootstrap didn't write:
$(printf '%s\n' "$extra" | sed 's/^/    /')
  Sources belong in compiler/src (or pass --force to delete these)."
    fi
  fi
  mkdir -p "$dest"
  # Only rewrite what changed, so Gleam recompiles as little as possible.
  (cd "$from" && find . -type f | sort) >"$WORK/install.list"
  while IFS= read -r f; do
    if ! cmp -s "$from/$f" "$dest/$f"; then
      mkdir -p "$(dirname "$dest/$f")"
      cp "$from/$f" "$dest/$f"
    fi
  done <"$WORK/install.list"
  (cd "$dest" && find . -type f ! -name .bea-generated | sort) |
    comm -23 - "$WORK/install.list" |
    while IFS= read -r f; do rm -f "$dest/$f"; done
  find "$dest" -mindepth 1 -type d -empty -delete
  {
    echo "# Written by scripts/bootstrap.sh: src/ is generated from compiler/src."
    echo "# Don't edit these files: the bootstrap refuses to overwrite edited ones."
    (cd "$dest" && find . -type f ! -name .bea-generated | sort |
      while IFS= read -r f; do sha256 "$f"; done)
  } >"$manifest"
}

mkdir -p "$WORK"
if [ "$quick" = 1 ]; then
  [ -d "$REPO/build/dev/erlang/bea/ebin" ] ||
    die "--quick needs this checkout's compiler built: run scripts/bootstrap.sh"
  compiler="$REPO/scripts/bea"
  compiler_name="this checkout's compiler"
  stage quick "$REPO"
else
  stage_a
  # A chain of trust recorded with the seed (see docs/self-hosting.md).
  if [ ${#via[@]} -eq 0 ] && [ -n "${SEED_VIA:-}" ]; then
    read -r -a via <<<"$SEED_VIA"
  fi
  for rev in ${via[@]+"${via[@]}"}; do
    name="via-$(git -C "$REPO" rev-parse --short "$rev")"
    rm -rf "$WORK/$name.src" && mkdir -p "$WORK/$name.src"
    git -C "$REPO" archive "$rev" gleam.toml manifest.toml compiler/src |
      tar -x -C "$WORK/$name.src"
    stage "$name" "$WORK/$name.src"
  done
  trusted=$compiler_name
  stage B "$REPO"
  stage C "$REPO"
  step "check" "compiler/src compiles to the same Gleam with $trusted and with compiler B"
  if ! diff -r "$WORK/B/gleam/src" "$WORK/C/gleam/src" >"$WORK/B-vs-C.diff"; then
    head -60 "$WORK/B-vs-C.diff" >&2
    die "the self-hosted compiler B compiles compiler/src differently from
  $trusted (full diff in build/bootstrap/B-vs-C.diff)."
  fi
fi

if [ "$install" = 1 ]; then
  step "install" "src/, generated from compiler/src"
  install_sources "$generated"
  step "build" "the repository (gleam build)"
  build_package "$REPO" "$WORK/repository.log"
  step "done" "scripts/bea runs the compiler built from compiler/src"
else
  step "done" "$compiler_name is $compiler"
fi
