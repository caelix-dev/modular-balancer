#!/usr/bin/env bash
# Reproduces the prototype-stage refusals of spike S1 (docs/feasibility.md F1).
# For each variant of spikes/multi_belt/data.lua it writes spikes/local-enable.lua, runs
# `fdev test` (the game is expected to refuse to load) and prints the prototype error from
# the test instance's log. spikes/local-enable.lua is restored to `return true` at the end.
# Run from anywhere: bash spikes/multi_belt/repro-load-errors.sh
set -u
repo="$(cd "$(dirname "$0")/../.." && pwd)"
ws="$(cd "$repo/.." && pwd)"
fdev="$ws/factorio-dev/target/release/fdev.exe"
log="${FDEV_TEST_LOG:-/e/factorio-dev/instances/factorio-test/factorio-current.log}"
enable="$repo/spikes/local-enable.lua"

for v in custom-layers belt-layer-subsets not-colliding-with-itself tiles-only loader-custom-layers; do
  printf 'return { variant = "%s" }\n' "$v" > "$enable"
  (cd "$ws" && "$fdev" test "$(basename "$repo")" > /dev/null 2>&1)
  echo "== $v (fdev test exit $?)"
  grep -E "Error|must collide" "$log" | head -n 3
done
echo 'return true' > "$enable"
