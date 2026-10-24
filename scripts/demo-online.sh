#!/usr/bin/env bash
# Two people in one online race on this Mac (#162): builds the Debug app, boots two iPhone simulators, installs it
# on both and launches it on each as its own dev player against a dev server that is already running. Not CI.
#
#   # terminal 1: the dev server (accounts in memory), a short queue and a short race
#   cd Packages/RegattaServer && ENV=dev QUEUE_LOCK_SECONDS=10 QUEUE_RACE_SECONDS=90 CATCH_FINISHERS=off swift run RegattaServer
#   # terminal 2
#   scripts/demo-online.sh [--auto] [--no-build] [--headless-second]
#
# In each simulator: tap Race online, agree to the terms once, and wait for the other. Both must join within
# QUEUE_LOCK_SECONDS of the first. --auto taps Race online and I agree for you at launch (`-tap`), so both queue at
# once. --no-build installs the app that is already built. --headless-second launches one simulator only and plays
# the second person with `regatta-loadclient --queue-player` (for a Mac two simulators are too much for).
#
#   DEMO_HOST     the server, host:port (default 127.0.0.1:8080; the simulators share the Mac's loopback)
#   DEMO_DEVICES  two simulators, comma-separated, each a name or a UDID (default "iPhone 17 Pro,iPhone 17e"; a name is
#                 the available one on the newest runtime). Not the iPhone 17: the test runs' simulator, which a
#                 test in another worktree reinstalls its own app on.
#   DEMO_PLAYERS  two dev player numbers (default "1 2": "Dev 1" and "Dev 2")
#
# The build holds the machine-wide build lock (scripts/heavy.sh): don't run this script under heavy.sh.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

host="${DEMO_HOST:-127.0.0.1:8080}"
IFS=',' read -r device_a device_b <<< "${DEMO_DEVICES:-iPhone 17 Pro,iPhone 17e}"
read -r player_a player_b <<< "${DEMO_PLAYERS:-1 2}"
bundle=com.phillreeder.regatta
derived="$root/.build/check/DerivedData"
app="$derived/Build/Products/Debug-iphonesimulator/Regatta.app"

auto=0
build=1
headless=0
for argument in "$@"; do
    case "$argument" in
        --auto) auto=1 ;;
        --no-build) build=0 ;;
        --headless-second) headless=1 ;;
        *) echo "usage: scripts/demo-online.sh [--auto] [--no-build] [--headless-second]" >&2; exit 2 ;;
    esac
done

if ! curl --silent --fail "http://$host/health" > /dev/null; then
    echo "demo-online.sh: no server at $host. Start it first:" >&2
    echo "  cd Packages/RegattaServer && ENV=dev QUEUE_LOCK_SECONDS=10 QUEUE_RACE_SECONDS=90 CATCH_FINISHERS=off swift run RegattaServer" >&2
    exit 1
fi

if (( build )); then
    echo "== build the Debug app"
    scripts/heavy.sh xcodebuild -project Regatta.xcodeproj -scheme Regatta -configuration Debug \
        -destination "generic/platform=iOS Simulator" -derivedDataPath "$derived" -quiet build
fi
[[ -d "$app" ]] || { echo "demo-online.sh: no app at $app (run without --no-build)" >&2; exit 1; }

# The UDID of the simulator $1 names: a UDID as it is, a name as the available device on the newest runtime (two
# runtimes can each have an "iPhone 17", and simctl won't choose).
udid_of() {
    xcrun simctl list devices available -j | python3 -c '
import json, sys
wanted = sys.argv[1]
runtimes = json.load(sys.stdin)["devices"]
for runtime in sorted(runtimes, reverse=True):
    for device in runtimes[runtime]:
        if wanted in (device["udid"], device["name"]):
            print(device["udid"])
            sys.exit(0)
sys.exit("demo-online.sh: no available simulator " + wanted)
' "$1"
}

# Boots the simulator $1 (a UDID) if it isn't, and installs the app. A simulator this boots is cold: sets cold.
cold=0
prepare() {
    if xcrun simctl boot "$1" > /dev/null 2>&1; then cold=1; fi
    xcrun simctl bootstatus "$1" > /dev/null
    xcrun simctl install "$1" "$app"
}

# The app's first launch on a simulator that has just booted takes longer than a short QUEUE_LOCK_SECONDS, and the
# fleet would lock on one of the two alone: --auto launches it there once beforehand, not queueing.
warm_up() {
    (( auto && cold )) || return 0
    echo "== a first launch on the simulators just booted (25 s)"
    local device
    for device in "$@"; do
        xcrun simctl launch "$device" "$bundle" -onlineHost "$host" > /dev/null
    done
    sleep 25
}

# Launches the app on the simulator $1 as the dev player $2.
launch() {
    local device=$1 player=$2
    xcrun simctl terminate "$device" "$bundle" > /dev/null 2>&1 || true
    local arguments=(-onlineHost "$host" -devIdentity "$player")
    if (( auto )); then arguments+=(-tap race-online,terms-agree); fi
    xcrun simctl launch "$device" "$bundle" "${arguments[@]}"
    echo "== $device: Dev $player"
}

device_a="$(udid_of "$device_a")"
open -a Simulator
# Both installed before either launches, so the two queue close together.
prepare "$device_a"
if (( headless )); then
    warm_up "$device_a"
    launch "$device_a" "$player_a"
    port="${host##*:}"
    echo "== the second person, headless: Dev $player_b"
    swift run --package-path Packages/RegattaServer regatta-loadclient --host "${host%:*}" --port "$port" --queue-player "$player_b"
else
    device_b="$(udid_of "$device_b")"
    prepare "$device_b"
    warm_up "$device_a" "$device_b"
    launch "$device_a" "$player_a"
    launch "$device_b" "$player_b"
    if (( auto )); then
        echo "Both are queueing. The fleet locks QUEUE_LOCK_SECONDS after the first join; the gun is 75 s after the lock."
    else
        echo "In each simulator: Race online, I agree, then wait for the other (within QUEUE_LOCK_SECONDS of the first)."
    fi
fi
