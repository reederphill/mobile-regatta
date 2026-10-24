#!/usr/bin/env bash
# The merge gate, here and in CI (ci.yml's `packages` job): builds each package with its tests and runs them.
# Tests build at -O: the simulation runs about 15x faster than at -Onone, and the tests are mostly simulation.
#
#   scripts/test.sh [--bots] [Package ...]     (default: every package)
#
# The bot suites (RegattaBotsTests, BotSuiteTests) pin bot behaviour, so they churn whenever the bots are tuned:
# they run nightly (nightly.yml), and here only with --bots. Any other narrowing is plain SwiftPM, e.g.
#   scripts/test.sh RegattaCore -- --filter WindTests
# Each package builds in .build/check/<package> (SwiftPM keys its build plan on the scratch path; scripts/e2e.sh and
# scripts/record-fixtures.sh reuse these builds).
set -euo pipefail
cd "$(dirname "$0")/.."

bots=0
packages=()
extra=()
while (( $# )); do
    case "$1" in
        --bots) bots=1 ;;
        --) shift; extra=("$@"); break ;;
        -*) echo "usage: scripts/test.sh [--bots] [Package ...] [-- <swift test arguments>]" >&2; exit 2 ;;
        *) packages+=("$1") ;;
    esac
    shift
done
(( ${#packages[@]} )) || packages=(RegattaCore RegattaProtocol RegattaClient RegattaServices RegattaServer)

skip=()
(( bots )) || skip=(--skip RegattaBotsTests --skip BotSuiteTests)

for package in "${packages[@]}"; do
    flags=(--package-path "Packages/$package" --scratch-path ".build/check/$package" -Xswiftc -O)
    echo "== $package"
    start=$SECONDS
    swift build --build-tests "${flags[@]}"
    swift test "${flags[@]}" ${skip[@]+"${skip[@]}"} ${extra[@]+"${extra[@]}"}
    echo "== PASS $package ($((SECONDS - start)) s)"
done
