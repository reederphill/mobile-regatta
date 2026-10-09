#!/usr/bin/env bash
# Records the render fixtures' scene logs and picks their freeze ticks by condition (#404, #466).
#
#   scripts/record-fixtures.sh --record  re-record every scene log in scripts/fixture-scenes.json (e.g. after a
#                                        default-class or bot change), then rewrite the ticks as below
#   scripts/record-fixtures.sh           rewrite each row's fixtures to the tick its condition picks
#   scripts/record-fixtures.sh --check   report each committed tick against the condition's pick, rewriting nothing
#                                        (exit 1 if any differs)
#
# Recording (`regatta-replay record-fixture`, #466): each scene is one short bot race on the default class, written
# as RegattaUITests/Fixtures/<log>: the lowest seed (of at most 200 from the scene's first) whose race meets every
# row of scripts/fixture-freeze-ticks.json naming that log, cut off at the last tick its fixtures need. A scene may
# script your seat (`FixtureScene`: a misjudging bot, a penalty turn at once, a head-up at the finish) so its moment
# comes often enough that a bounded search always finds it. A scene no seed meets fails the run; nothing is written
# for it.
#
# Ticks: one run rewrites each `freezeTick` in RegattaUITests/Fixtures/<name>.json to the first tick (every 10)
# meeting its row's condition; nothing else in a fixture changes. The conditions read the core race only, so they
# are the core half of what each fixture's test checks (RenderFixtureTests, BoatCueTests); the test still checks the
# drawn half. Fixtures the table doesn't name keep their hand-set ticks (a fixed time into the log), and a recorded
# log reaches them. Look at the renders CI makes (render-actuals, scripts/adopt-references.sh) before adopting them.
#
# The tool is `regatta-replay` (Packages/RegattaCore, release build, through scripts/heavy.sh); the conditions are
# documented on `FreezeTickRow`, the scenes on `FixtureScene`.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

mode=()
record=false
case "${1:-}" in
    "") ;;
    --check) mode=(--check) ;;
    --record) record=true ;;
    -h | --help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: scripts/record-fixtures.sh [--record | --check]" >&2; exit 2 ;;
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

if $record; then
    "$tool" record-fixture RegattaUITests/Fixtures scripts/fixture-freeze-ticks.json scripts/fixture-scenes.json
fi
"$tool" freeze-ticks ${mode[@]+"${mode[@]}"} RegattaUITests/Fixtures scripts/fixture-freeze-ticks.json
