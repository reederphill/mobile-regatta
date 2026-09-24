#!/usr/bin/env bash
# Runs the tests of every Linux package (RegattaCore, with its RegattaBots target, which runs on the
# race server too; RegattaProtocol) on the pinned replay platform (the race server's toolchain,
# C library and architecture; ADR 0002), in debug and release, with podman or docker.
#
#   scripts/linux-test.sh
#
# RegattaCore's golden test asserts Tests/Goldens.json here. Each run prints its digest as
#   GOLDEN simulationVersion=<version> digest=<hex>
# which is the value for a new Goldens.json row after a simulationRevision bump.
#
# Changing IMAGE changes the simulation version: update replayPlatform in
# Sources/RegattaCore/SimulationVersion.swift, bump simulationRevision and add a golden row.
#
# The container fetches package dependencies (swift-crypto) from GitHub. Behind a proxy, pass
# extra container arguments in CONTAINER_RUN_ARGS, e.g.
#   CONTAINER_RUN_ARGS="--network host -e HTTPS_PROXY=$HTTPS_PROXY" scripts/linux-test.sh
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

read -r -a run_args <<< "${CONTAINER_RUN_ARGS:-}"

root="$(cd "$(dirname "$0")/.." && pwd)"
log="$(mktemp)"
trap 'rm -f "$log"' EXIT

# Packages under Packages/, tested in this order. Each one's tests run in debug and release.
# Packages depend on each other by relative path, so the whole Packages/ folder is mounted.
PACKAGES="RegattaCore RegattaProtocol"

# Build inside the container's own scratch paths so Linux artefacts never mix with the host's .build.
"$engine" run --rm --platform "$PLATFORM" ${run_args[@]+"${run_args[@]}"} \
    -e REGATTA_EXPECT_REPLAY_PLATFORM=1 -e PACKAGES="$PACKAGES" \
    -v "$root/Packages:/packages" -w /packages \
    "$IMAGE" \
    bash -euo pipefail -c '
        swift --version
        for package in $PACKAGES; do
            echo "== $package: debug =="
            swift test --package-path "/packages/$package" --scratch-path "/tmp/build-debug-$package"
            echo "== $package: release =="
            swift test --package-path "/packages/$package" -c release -Xswiftc -enable-testing \
                --scratch-path "/tmp/build-release-$package"
        done
    ' 2>&1 | tee "$log"

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

# RegattaBots built and its tests ran in both configurations: its replay test prints one line each.
bots="$(grep -c 'REGATTABOTS replay digest=' "$log" || true)"
if [[ "$bots" != "2" ]]; then
    echo "linux-test.sh: expected 2 REGATTABOTS lines (debug and release), got $bots" >&2
    exit 1
fi
echo "RegattaBots tests ran in debug and release."
