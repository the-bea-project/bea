#!/usr/bin/env bash
# Migrate compiler modules from Gleam to Bea, mechanically:
#
#   tools/migrate/migrate.sh bea/span bea/style ...
#
# For each module, compiler/src/<module>.gleam is translated by
# gleam_to_bea.py into compiler/src/<module>.bea (`git mv` first, so git
# history follows the file) and formatted with `bea format`. Then check the
# stage with tools/migrate/check.sh (which runs the bootstrap) and the test
# suites before committing it.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
cd "$REPO"
[ $# -gt 0 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
for module in "$@"; do
  gleam="compiler/src/$module.gleam"
  bea="compiler/src/$module.bea"
  [ -f "$gleam" ] || { echo "migrate: no $gleam" >&2; exit 1; }
  [ ! -e "$bea" ] || { echo "migrate: $bea exists already" >&2; exit 1; }
  original=$(mktemp)
  cp "$gleam" "$original"
  git mv "$gleam" "$bea"
  if ! python3 -I tools/migrate/gleam_to_bea.py "$original" "$bea"; then
    git mv "$bea" "$gleam"
    cp "$original" "$gleam"
    rm -f "$original"
    exit 1
  fi
  rm -f "$original"
  echo "translated $gleam -> $bea"
done
files=()
for module in "$@"; do files+=("compiler/src/$module.bea"); done
scripts/bea format "${files[@]}"
