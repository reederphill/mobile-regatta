#!/usr/bin/env bash
# Runs the RegattaCore tests on the pinned replay platform (the race server's toolchain,
# C library and architecture; ADR 0002), in debug and release, with podman or docker.
#
#   scripts/linux-test.sh
#
# The golden test asserts Tests/Goldens.json here. Each run prints its digest as
#   GOLDEN simulationVersion=<version> digest=<hex>
# which is the value for a new Goldens.json row after a simulationRevision bump.
#
# Changing IMAGE changes the simulation version: update replayPlatform in
# Sources/RegattaCore/SimulationVersion.swift, bump simulationRevision and add a golden row.
set -euo pipefail

IMAGE="swift:6.3.3-noble@sha256:8de8ea332a61e961ead4ef41029c2552b18e1a70dd5942d25ecf7d8de2eec5b5"
PLATFORM="linux/amd64"

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

root="$(cd "$(dirname "$0")/.." && pwd)"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# Build inside the container's own scratch path so Linux artefacts never mix with the host's .build.
"$engine" run --rm --platform "$PLATFORM" \
    -e REGATTA_EXPECT_REPLAY_PLATFORM=1 \
    -v "$root/Packages/RegattaCore:/src" -w /src \
    "$IMAGE" \
    bash -euo pipefail -c '
        swift --version
        echo "== debug =="
        swift test --scratch-path /tmp/build-debug
        echo "== release =="
        swift test -c release -Xswiftc -enable-testing --scratch-path /tmp/build-release
    ' 2>&1 | tee "$log"

digests="$(grep -o 'GOLDEN simulationVersion=.*' "$log" | sort -u)"
echo
echo "Golden digests (debug and release):"
echo "$digests"
if [[ "$(echo "$digests" | wc -l | tr -d ' ')" != "1" ]]; then
    echo "linux-test.sh: debug and release digests differ" >&2
    exit 1
fi
