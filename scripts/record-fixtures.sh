#!/usr/bin/env bash
# Picks the render fixtures' freeze ticks from their logs by condition (#404): after a fixture log is re-recorded,
# one run of this rewrites each `freezeTick` in RegattaUITests/Fixtures/<name>.json to the first tick (every 10)
# meeting its row's condition in scripts/fixture-freeze-ticks.json; nothing else in a fixture changes. The logs
# themselves are recorded as before; this doesn't sail or re-record them. Look at the renders CI makes of the new
# ticks (render-actuals, scripts/adopt-references.sh) before adopting them.
#
#   scripts/record-fixtures.sh           rewrite each row's fixtures to the tick its condition picks
#   scripts/record-fixtures.sh --check   report each committed tick against the condition's pick, rewriting nothing
#                                        (exit 1 if any differs)
#
# The conditions read the core race only, so they are the core half of what each fixture's test checks
# (RenderFixtureTests, BoatCueTests); the test still checks the drawn half. The tool is `regatta-replay
# freeze-ticks` (Packages/RegattaCore, release build, through scripts/heavy.sh); its conditions are documented on
# `FreezeTickRow`. Fixtures the table doesn't name keep their hand-set ticks (a fixed time into the log).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

mode=()
case "${1:-}" in
    "") ;;
    --check) mode=(--check) ;;
    -h | --help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: scripts/record-fixtures.sh [--check]" >&2; exit 2 ;;
esac

package=Packages/RegattaCore
scratch=.build/check/RegattaCore
tool="$scratch/release/regatta-replay"
build_log="$(mktemp)"
trap 'rm -f "$build_log"' EXIT
# A failed build stops here: never check or rewrite ticks with whatever binary an earlier build left.
if ! scripts/heavy.sh swift build -c release --package-path "$package" --scratch-path "$scratch" \
    --product regatta-replay >"$build_log" 2>&1; then
    grep -E "error" "$build_log" >&2 || tail -20 "$build_log" >&2
    echo "record-fixtures.sh: building the tool failed" >&2
    exit 1
fi
grep -E "warning: unre" "$build_log" || true
[[ -x "$tool" ]] || { echo "record-fixtures.sh: no tool at $tool" >&2; exit 1; }

"$tool" freeze-ticks ${mode[@]+"${mode[@]}"} RegattaUITests/Fixtures scripts/fixture-freeze-ticks.json
