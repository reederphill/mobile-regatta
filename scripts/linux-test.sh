#!/usr/bin/env bash
# Checks what only the pinned Linux replay platform can (the race server's toolchain, C library and
# architecture; ADR 0002), with podman or docker:
# - RegattaCore's golden test, which asserts Tests/Goldens.json here, and RegattaBots' replay race, each in
#   debug and release, which must agree;
# - every package builds with its tests (RegattaCore with RegattaBots, RegattaProtocol, RegattaClient,
#   RegattaServer), since
#   each must build on the race server.
# Unit tests run on macOS (scripts/check.sh). --all runs every package's tests here too.
#
#   scripts/linux-test.sh [--all]
#
# Each golden run prints its digest as
#   GOLDEN simulationVersion=<version> digest=<hex>
# which is the value for a new Goldens.json row after a simulationRevision bump.
#
# Changing IMAGE changes the simulation version: update replayPlatform in
# Sources/RegattaCore/SimulationVersion.swift, bump simulationRevision and add a golden row.
#
# Builds persist between runs, so swift-crypto builds once: in a named volume per image, or in LINUX_SCRATCH,
# a host directory (CI caches it). Each package has its own scratch directory there: on Linux, SwiftPM fails
# when root packages take turns with one ("repositories/swift-crypto already exists"). A step that
# fails on SwiftPM's intermittent resource-copy error ("I/O error (code: 4)", seen on Rosetta) is retried.
# The whole run is killed after LINUX_TEST_TIMEOUT_MINUTES (default 30).
#
# The container fetches package dependencies (swift-crypto) from GitHub. Behind a proxy, pass
# extra container arguments in CONTAINER_RUN_ARGS, e.g.
#   CONTAINER_RUN_ARGS="--network host -e HTTPS_PROXY=$HTTPS_PROXY" scripts/linux-test.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/scripts/lib.sh"

IMAGE="swift:6.3.3-noble@sha256:8de8ea332a61e961ead4ef41029c2552b18e1a70dd5942d25ecf7d8de2eec5b5"
PLATFORM="linux/amd64"

mode=golden
case "${1:-}" in
    "") ;;
    --all) mode=all ;;
    *) echo "usage: scripts/linux-test.sh [--all]" >&2; exit 2 ;;
esac

engine="${CONTAINER_ENGINE:-}"
if [[ -z "$engine" ]]; then
    if command -v podman >/dev/null 2>&1; then
        engine=podman
    elif command -v docker >/dev/null 2>&1; then
        engine=docker
    else
        echo "linux-test.sh: needs podman or docker (or set CONTAINER_ENGINE)" >&2
        exit 1
    fi
fi

# Smaller podman machines have died mid-build, or deadlocked it.
if [[ "$engine" == podman ]]; then
    memory="$(podman info --format '{{.Host.MemTotal}}' 2>/dev/null || echo 0)"
    if (( memory > 0 && memory < 5500000000 )); then
        echo "linux-test.sh: warning: the podman machine has $((memory / 1048576)) MiB; give it at least 6 GiB" >&2
    fi
fi

read -r -a run_args <<< "${CONTAINER_RUN_ARGS:-}"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# Packages under Packages/, built in this order. They depend on each other by relative path, so the whole
# Packages/ folder is mounted.
PACKAGES="RegattaCore RegattaProtocol RegattaClient RegattaServer"

# Linux artefacts never mix with the host's .build.
scratch="${LINUX_SCRATCH:-regatta-linux-scratch-$(echo "${IMAGE##*sha256:}" | cut -c1-12)}"
[[ -n "${LINUX_SCRATCH:-}" ]] && mkdir -p "$LINUX_SCRATCH"
name="regatta-linux-test-$$"
timeout_minutes="${LINUX_TEST_TIMEOUT_MINUTES:-30}"

set +e
with_timeout $((timeout_minutes * 60)) "$engine" run --rm --name "$name" --platform "$PLATFORM" \
    ${run_args[@]+"${run_args[@]}"} \
    -e REGATTA_EXPECT_REPLAY_PLATFORM=1 -e PACKAGES="$PACKAGES" -e MODE="$mode" \
    -v "$root/Packages:/packages" -v "$scratch:/scratch" -w /packages \
    "$IMAGE" \
    bash -uo pipefail -c '
        swift --version
        # Retries a step that failed on the resource-copy error, which leaves the rest of the build intact.
        step() {
            for attempt in 1 2 3; do
                "$@" 2>&1 | tee /tmp/step.log
                status=${PIPESTATUS[0]}
                [[ $status == 0 ]] && return 0
                grep -q "I/O error (code: 4)" /tmp/step.log || return "$status"
                echo "== resource-copy I/O error, retrying ($attempt) =="
            done
            return 1
        }
        for config in debug release; do
            for package in $PACKAGES; do
                flags=(-c "$config" --scratch-path "/scratch/$package/$config")
                [[ $config == release ]] && flags+=(-Xswiftc -enable-testing)
                path=(--package-path "/packages/$package")
                if [[ $MODE == all ]]; then
                    echo "== $package: test $config =="
                    step swift test "${path[@]}" "${flags[@]}" || exit 1
                elif [[ $package == RegattaCore ]]; then
                    echo "== $package: golden and bot replay, $config =="
                    step swift test "${path[@]}" "${flags[@]}" --filter "GoldenTests|BotReplayTests" || exit 1
                else
                    echo "== $package: build with tests, $config =="
                    step swift build --build-tests "${path[@]}" "${flags[@]}" || exit 1
                fi
            done
        done
    ' 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e
if [[ "$status" == "$TIMED_OUT" ]]; then
    echo "linux-test.sh: timed out after $timeout_minutes minutes" >&2
    "$engine" kill "$name" >/dev/null 2>&1 || true
fi
[[ "$status" == 0 ]] || exit "$status"

# One GOLDEN line per configuration (debug, release), and both the same. Only RegattaCore prints one.
lines="$(grep -o 'GOLDEN simulationVersion=.*' "$log" || true)"
echo
echo "Golden digests (debug and release):"
echo "$lines"
count="$(printf '%s' "$lines" | grep -c . || true)"
if [[ "$count" != "2" ]]; then
    echo "linux-test.sh: expected 2 GOLDEN lines (debug and release), got $count" >&2
    exit 1
fi
if [[ "$(printf '%s\n' "$lines" | sort -u | wc -l | tr -d ' ')" != "1" ]]; then
    echo "linux-test.sh: debug and release digests differ" >&2
    exit 1
fi

# RegattaBots built and its replay test ran in both configurations: it prints one line each.
# It sails a different race from the golden (bots, contacts, penalty turns), so it must agree too.
bots="$(grep -o 'REGATTABOTS replay digest=.*' "$log" || true)"
echo
echo "RegattaBots replay digests (debug and release):"
echo "$bots"
count="$(printf '%s' "$bots" | grep -c . || true)"
if [[ "$count" != "2" ]]; then
    echo "linux-test.sh: expected 2 REGATTABOTS lines (debug and release), got $count" >&2
    exit 1
fi
if [[ "$(printf '%s\n' "$bots" | sort -u | wc -l | tr -d ' ')" != "1" ]]; then
    echo "linux-test.sh: debug and release RegattaBots replay digests differ" >&2
    exit 1
fi
