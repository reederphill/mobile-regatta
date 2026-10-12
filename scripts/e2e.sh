#!/usr/bin/env bash
# The online end-to-end run (#68, #161): builds RegattaServer, starts Postgres in a temporary directory and the
# server on it with ENV=dev on a free local port, waits for /health, runs the app's online UI tests on the simulator
# against it, and always stops both.
#
#   1. OnlineRaceUITests races a dev instant race with bots to its close; OnlineAccountUITests signs in as dev
#      players, accepts the terms, relaunches, and meets a suspension and the cooldown.
#   2. The server is restarted with TERMS_VERSION=2 on the same database, and
#      OnlineAccountUITests/testServerRestartedWithANewTermsVersionAsksAgain meets the new version as the player
#      who accepted the old one in 1.
#
#   scripts/e2e.sh [extra xcodebuild arguments, e.g. -derivedDataPath DerivedData -resultBundlePath E2E.xcresult]
#
# The app runs on E2E_DESTINATION (default the iPhone 17 simulator). The build and each test run are killed
# after E2E_STEP_TIMEOUT_MINUTES (default 15). The server's and Postgres' logs are printed if anything fails.
# A -resultBundlePath names the first run's bundle; the second's is the same name with -terms-bump.
#
# Postgres is Homebrew's postgresql@17 (macOS runners have no Docker, so not a container), or the binaries in
# E2E_POSTGRES_BIN: initdb into a temporary directory, loopback TCP only, trust authentication, removed at the end.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/lib.sh

destination="${E2E_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
step_seconds=$(( ${E2E_STEP_TIMEOUT_MINUTES:-15} * 60 ))
# check.sh's RegattaServer build, with its flags, so a checked tree builds nothing here.
scratch="$root/.build/check/RegattaServer"
optimize=(-Xswiftc -O)
log="$(mktemp -t regatta-e2e-server)"
server_pid=""
postgres_bin=""
postgres_dir=""
database_url=""
port=""

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

stop_server() {
    if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
    server_pid=""
}

stop_everything() {
    local status=$?
    stop_server
    if [[ -n "$postgres_dir" ]]; then
        "$postgres_bin/pg_ctl" -D "$postgres_dir/data" -m fast -w stop > /dev/null 2>&1 || true
    fi
    if (( status != 0 )); then
        echo "e2e.sh: failed ($status); server log:" >&2
        tail -n 100 "$log" >&2 || true
        if [[ -n "$postgres_dir" ]]; then
            echo "e2e.sh: Postgres log:" >&2
            tail -n 40 "$postgres_dir/postgres.log" >&2 || true
        fi
    fi
    rm -f "$log"
    [[ -z "$postgres_dir" ]] || rm -rf "$postgres_dir"
}
trap stop_everything EXIT

# Starts Postgres on a free loopback port, in a directory of its own, and sets database_url.
start_postgres() {
    postgres_bin="${E2E_POSTGRES_BIN:-}"
    if [[ -z "$postgres_bin" ]]; then
        local prefix
        prefix="$(brew --prefix postgresql@17 2>/dev/null || true)"
        postgres_bin="$prefix/bin"
    fi
    if [[ ! -x "$postgres_bin/initdb" || ! -x "$postgres_bin/pg_ctl" ]]; then
        postgres_bin=""
        echo "e2e.sh: no Postgres: brew install postgresql@17, or set E2E_POSTGRES_BIN to its bin directory" >&2
        exit 1
    fi
    local directory postgres_port
    directory="$(mktemp -d -t regatta-e2e-postgres)"
    postgres_port="$(free_port)"
    LC_ALL=en_US.UTF-8 "$postgres_bin/initdb" -D "$directory/data" -U regatta --auth=trust -E UTF8 > "$directory/initdb.log" 2>&1 \
        || { cat "$directory/initdb.log" >&2; rm -rf "$directory"; exit 1; }
    # Loopback TCP only: a socket file's path in the temporary directory would be too long for one.
    cat >> "$directory/data/postgresql.conf" <<EOF
port = $postgres_port
listen_addresses = '127.0.0.1'
unix_socket_directories = ''
fsync = off
EOF
    postgres_dir="$directory"
    LC_ALL=en_US.UTF-8 "$postgres_bin/pg_ctl" -D "$directory/data" -l "$directory/postgres.log" -w start > /dev/null
    database_url="postgres://regatta@127.0.0.1:$postgres_port/postgres"
}

# Starts the server on a free port with TERMS_VERSION=$1 and waits for /health; sets port.
start_server() {
    local terms_version=$1
    port="$(free_port)"
    echo "== start RegattaServer on 127.0.0.1:$port (ENV=dev, Postgres, TERMS_VERSION=$terms_version)"
    ENV=dev HOST=127.0.0.1 PORT="$port" REGATTA_DATABASE_URL="$database_url" TERMS_VERSION="$terms_version" \
        "$server" >> "$log" 2>&1 &
    server_pid=$!
    for _ in $(seq 1 60); do
        curl --silent --fail "http://127.0.0.1:$port/health" > /dev/null 2>&1 && break
        kill -0 "$server_pid" 2>/dev/null || { echo "e2e.sh: the server exited" >&2; exit 1; }
        sleep 0.5
    done
    curl --silent --show-error --fail "http://127.0.0.1:$port/health"
    echo
}

echo "== build RegattaServer"
with_timeout "$step_seconds" swift build --package-path Packages/RegattaServer --scratch-path "$scratch" "${optimize[@]}" --product RegattaServer
server="$(swift build --package-path Packages/RegattaServer --scratch-path "$scratch" "${optimize[@]}" --show-bin-path)/RegattaServer"

echo "== start Postgres"
start_postgres

start_server 1
echo "== OnlineRaceUITests and OnlineAccountUITests against 127.0.0.1:$port"
# xcodebuild hands TEST_RUNNER_-prefixed variables to the test process without the prefix.
with_timeout "$step_seconds" env TEST_RUNNER_REGATTA_ONLINE_HOST="127.0.0.1:$port" \
    xcodebuild test -project Regatta.xcodeproj -scheme Regatta -destination "$destination" \
    -only-testing:RegattaUITests/OnlineRaceUITests -only-testing:RegattaUITests/OnlineAccountUITests "$@"

# The terms move on (#161): the same database, a server that asks for version 2.
stop_server
start_server 2
# xcodebuild won't write over the first run's result bundle.
bump_arguments=()
previous=""
for argument in "$@"; do
    if [[ "$previous" == -resultBundlePath ]]; then argument="${argument%.xcresult}-terms-bump.xcresult"; fi
    bump_arguments+=("$argument")
    previous="$argument"
done
echo "== OnlineAccountUITests, the terms bump, against 127.0.0.1:$port"
with_timeout "$step_seconds" env TEST_RUNNER_REGATTA_ONLINE_HOST="127.0.0.1:$port" TEST_RUNNER_REGATTA_E2E_PHASE=terms-bump \
    xcodebuild test -project Regatta.xcodeproj -scheme Regatta -destination "$destination" \
    -only-testing:RegattaUITests/OnlineAccountUITests/testServerRestartedWithANewTermsVersionAsksAgain \
    ${bump_arguments[@]+"${bump_arguments[@]}"}
echo "e2e.sh: passed"
