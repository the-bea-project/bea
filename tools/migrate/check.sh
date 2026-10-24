#!/usr/bin/env bash
# Check a migration stage: is the compiler, with some of its modules now
# written in Bea, still the trusted seed's program?
#
#   1. scripts/bootstrap.sh --no-install: the seed (compiler A) compiles
#      compiler/src, the result (B) compiles it again (C), and A and B must
#      generate identical Gleam.
#   2. The seed's own Gleam sources and the Gleam that A generated from
#      compiler/src are parsed with glance and compared definition by
#      definition (tools/migrate/equiv), so every migrated module is shown
#      to be the original Gleam module, up to comments and layout.
#
# The test suites are run separately (see docs/self-hosting.md).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
. bootstrap/seed.env
scripts/bootstrap.sh --no-install
seed="$REPO/build/migrate/seed"
generated="$REPO/build/migrate/generated"
rm -rf "$seed" "$generated" && mkdir -p "$seed" "$generated"
git archive "$SEED_TREE" src | tar -x -C "$seed"
cp -R "$REPO/build/bootstrap/B/gleam/src" "$generated/src"
# Both through `gleam format` first: glance doesn't read everything Gleam
# does (such as `[a, ..rest,]`, which Bea's code generation writes), and
# formatting doesn't change a program.
gleam format "$seed/src" "$generated/src"
echo
echo "Comparing the seed's Gleam with the Gleam generated from compiler/src:"
(cd tools/migrate/equiv && gleam run -- "$seed/src" "$generated/src")
