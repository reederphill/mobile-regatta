#!/usr/bin/env bash
# Runs the golden scenario in two separate test processes and compares the printed digests.
# Each process gets its own hash seed, so this catches Set or Dictionary iteration order
# leaking into the simulation. No golden constant is asserted here (ADR 0002): it runs on macOS.
#
#   scripts/check-digest-stable.sh
set -euo pipefail

cd "$(dirname "$0")/../Packages/RegattaCore"
unset SWIFT_DETERMINISTIC_HASHING

run() {
    swift test --filter GoldenTests 2>&1 | tee /dev/stderr | grep -o 'GOLDEN simulationVersion=.*'
}

first="$(run)"
second="$(run)"
echo "first:  $first"
echo "second: $second"
if [[ -z "$first" || "$first" != "$second" ]]; then
    echo "check-digest-stable.sh: digests differ between processes" >&2
    exit 1
fi
echo "Digest stable across processes."
