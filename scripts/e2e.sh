#!/usr/bin/env bash
# The online end-to-end run (#68): builds RegattaServer and starts it with ENV=dev on a free local port,
# waits for /health, runs the app's online UI test (OnlineRaceUITests) on the simulator against it, and
# always stops the server. The test races a dev instant race with bots to its close.
#
#   scripts/e2e.sh [extra xcodebuild arguments, e.g. -derivedDataPath DerivedData -resultBundlePath E2E.xcresult]
#
# The app runs on E2E_DESTINATION (default the iPhone 17 simulator). The build and the test are each killed
# after E2E_STEP_TIMEOUT_MINUTES (default 15). The server's log is printed if anything fails.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/lib.sh

destination="${E2E_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
step_seconds=$(( ${E2E_STEP_TIMEOUT_MINUTES:-15} * 60 ))
scratch="$root/.build/check"
log="$(mktemp -t regatta-e2e-server)"
server_pid=""

stop_server() {
    local status=$?
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    if (( status != 0 )); then
        echo "e2e.sh: failed ($status); server log:" >&2
        tail -n 100 "$log" >&2 || true
    fi
    rm -f "$log"
}
trap stop_server EXIT

echo "== build RegattaServer"
with_timeout "$step_seconds" swift build --package-path Packages/RegattaServer --scratch-path "$scratch" --product RegattaServer
server="$(swift build --package-path Packages/RegattaServer --scratch-path "$scratch" --show-bin-path)/RegattaServer"

port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
echo "== start RegattaServer on 127.0.0.1:$port (ENV=dev)"
ENV=dev HOST=127.0.0.1 PORT="$port" "$server" > "$log" 2>&1 &
server_pid=$!
for _ in $(seq 1 60); do
    curl --silent --fail "http://127.0.0.1:$port/health" > /dev/null 2>&1 && break
    kill -0 "$server_pid" 2>/dev/null || { echo "e2e.sh: the server exited" >&2; exit 1; }
    sleep 0.5
done
curl --silent --show-error --fail "http://127.0.0.1:$port/health"
echo

echo "== OnlineRaceUITests against 127.0.0.1:$port"
# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process without the prefix.
with_timeout "$step_seconds" env TEST_RUNNER_REGATTA_ONLINE_HOST="127.0.0.1:$port" \
    xcodebuild test -project Regatta.xcodeproj -scheme Regatta -destination "$destination" \
    -only-testing:RegattaUITests/OnlineRaceUITests "$@"
echo "e2e.sh: passed"
