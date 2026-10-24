#!/usr/bin/env bash
# The online end-to-end run (#68, #161, #162): builds RegattaServer and the loadclient, starts Postgres in a temporary
# directory and the server on it with ENV=dev on a free local port, waits for /health, runs the app's online UI tests
# on the simulator against it, and always stops both. Each phase is a server of its own settings on the same
# database, with one RACE_TOKEN_SECRET throughout; REGATTA_E2E_PHASE tells the tests which one is running.
#
#   1. account: OnlineRaceUITests races a dev instant race with bots to its close; OnlineAccountUITests signs in as
#      dev players, accepts the terms, joins the queue and leaves it, relaunches, and meets a suspension and the
#      cooldown.
#   2. terms-bump: TERMS_VERSION=2. OnlineAccountUITests/testServerRestartedWithANewTermsVersionAsksAgain meets the
#      new version as the player who accepted the old one in 1.
#   3. race: a 4 s queue and a 12 s race. OnlineQueueRaceUITests queues, races to the close, leaves a briefing,
#      rejoins a race it dropped out of, leaves one for good, and gets its livery back from the server.
#   4. pair: a 75 s queue and a 75 s race, and a headless second person (regatta-loadclient --queue-player 7001) queued beside the
#      app, when the test says the app is about to join: OnlineQueueRaceUITests/testTwoHumansShareOneFleet.
#   5. kill: the server is killed (-9) while the app is in a race and started again on the same port and database:
#      OnlineQueueRaceUITests/testServerKilledMidRaceCancelsToHome. No retry: a second try would find no kill.
#   6. delete (#166): the race phase's queue and race. OnlineDeletionUITests races dev player 9166 to a close, deletes
#      her online data from Settings and relaunches; then the script reads Postgres with psql: no text column names
#      T:dev-9166 or G:dev-9166 but data_deletions.game_player_id, race_players has a deleted: seat, and the device's
#      analytics events grew during the phase (the real transport got batches through the gate).
#
#   scripts/e2e.sh [extra xcodebuild arguments, e.g. -derivedDataPath DerivedData -resultBundlePath E2E.xcresult]
#
# The app runs on E2E_DESTINATION (default the iPhone 17 simulator). The build and each test run are killed
# after E2E_STEP_TIMEOUT_MINUTES (default 15). The server's and Postgres' logs are printed if anything fails.
# A -resultBundlePath names the first run's bundle; each later phase's is the same name with -<phase>.
#
# Postgres is Homebrew's postgresql@17 (macOS runners have no Docker, so not a container), or the binaries in
# E2E_POSTGRES_BIN: initdb into a temporary directory, loopback TCP only, trust authentication, removed at the end.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/lib.sh

destination="${E2E_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
step_seconds=$(( ${E2E_STEP_TIMEOUT_MINUTES:-15} * 60 ))
# scripts/test.sh's RegattaServer build, with its flags, so a tested tree builds nothing here.
scratch="$root/.build/check/RegattaServer"
optimize=(-Xswiftc -O)
log="$(mktemp -t regatta-e2e-server)"
server_pid=""
helper_pid=""
killer_pid=""
# One key for every phase: a race token a killed server signed still verifies on the one that replaces it (#162).
token_secret="e2e-$(uuidgen)-$(uuidgen)"
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
    # The kill phase's second server is the killer's child: it goes first, or it would outlive the run.
    [[ -z "$killer_pid" ]] || pkill -P "$killer_pid" 2>/dev/null || true
    for pid in "$helper_pid" "$killer_pid"; do
        [[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true
    done
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

# Starts the server on port $1 ("free": a free one) with the environment assignments that follow, and waits for
# /health; sets port.
start_server() {
    local wanted=$1
    shift
    if [[ "$wanted" == free ]]; then port="$(free_port)"; else port="$wanted"; fi
    echo "== start RegattaServer on 127.0.0.1:$port (ENV=dev, Postgres${*:+, $*})"
    env ENV=dev HOST=127.0.0.1 PORT="$port" REGATTA_DATABASE_URL="$database_url" RACE_TOKEN_SECRET="$token_secret" "$@" \
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

# The caller's xcodebuild arguments for phase $1: xcodebuild won't write over an earlier phase's result bundle, and
# with "no-retry" as $2 the retry flags are left out. Sets phase_arguments.
arguments_for() {
    local phase=$1 retry=${2:-retry} previous="" skip=0
    phase_arguments=()
    shift $(( $# > 1 ? 2 : 1 ))
    for argument in "${caller_arguments[@]+"${caller_arguments[@]}"}"; do
        if (( skip )); then skip=0; previous="$argument"; continue; fi
        if [[ "$retry" == no-retry ]]; then
            if [[ "$argument" == -retry-tests-on-failure ]]; then previous="$argument"; continue; fi
            if [[ "$argument" == -test-iterations ]]; then skip=1; previous="$argument"; continue; fi
        fi
        if [[ "$previous" == -resultBundlePath ]]; then argument="${argument%.xcresult}-$phase.xcresult"; fi
        phase_arguments+=("$argument")
        previous="$argument"
    done
}

# Runs the UI tests named by the -only-testing arguments that follow, as phase $1 ("" for the first).
run_tests() {
    local phase=$1
    shift
    with_timeout "$step_seconds" env TEST_RUNNER_REGATTA_ONLINE_HOST="127.0.0.1:$port" TEST_RUNNER_REGATTA_E2E_PHASE="$phase" \
        xcodebuild test -project Regatta.xcodeproj -scheme Regatta -destination "$destination" "$@" \
        ${phase_arguments[@]+"${phase_arguments[@]}"}
}

# Runs one SQL statement against the run's database; prints its rows, unaligned, fields split by |.
query() {
    "$postgres_bin/psql" "$database_url" --no-psqlrc --tuples-only --no-align --set ON_ERROR_STOP=1 --command "$1"
}

# The delete phase's server-side acceptance (#166, T7); exits 1 on any miss. $1 is the device-event count before it.
check_deletion() {
    local before=$1 failed=0 table column count after
    # The same scan as PlayerDataStoreTests.references: every text column of every table.
    while IFS='|' read -r table column; do
        [[ -z "$table" || "$table.$column" == data_deletions.game_player_id ]] && continue
        count="$(query "SELECT count(*) FROM \"$table\" WHERE \"$column\" = ANY('{T:dev-9166,G:dev-9166}')")"
        if (( count > 0 )); then
            echo "e2e.sh: delete: $count rows of $table.$column still name dev player 9166" >&2
            failed=1
        fi
    done < <(query "SELECT table_name, column_name FROM information_schema.columns
                    WHERE table_schema = current_schema() AND data_type = 'text' ORDER BY 1, 2")
    count="$(query "SELECT count(*) FROM race_players WHERE player_id LIKE 'deleted:%'")"
    echo "== delete: race_players seats held by a deleted: id: $count"
    (( count >= 1 )) || { echo "e2e.sh: delete: no race_players seat was anonymised" >&2; failed=1; }
    after="$(query "SELECT count(*) FROM analytics_events WHERE source = 'device'")"
    echo "== delete: device analytics events: $before before the phase, $after after"
    (( after > before )) || { echo "e2e.sh: delete: no device analytics arrived during the phase" >&2; failed=1; }
    (( failed == 0 )) || exit 1
    echo "== delete: no row names T:dev-9166 or G:dev-9166 outside data_deletions.game_player_id"
}

# Waits (ten minutes at most) until the server on port $1 has a race: a test's word that it has got that far.
wait_for_a_race() {
    local races
    for _ in $(seq 1 600); do
        races="$(curl --silent "http://127.0.0.1:$1/health" | python3 -c 'import json, sys; print(json.load(sys.stdin).get("races", 0))' 2>/dev/null || echo 0)"
        (( races >= 1 )) && return 0
        sleep 1
    done
    return 1
}

caller_arguments=("$@")

echo "== build RegattaServer and regatta-loadclient"
with_timeout "$step_seconds" swift build --package-path Packages/RegattaServer --scratch-path "$scratch" "${optimize[@]}" --product RegattaServer
with_timeout "$step_seconds" swift build --package-path Packages/RegattaServer --scratch-path "$scratch" "${optimize[@]}" --product regatta-loadclient
bin="$(swift build --package-path Packages/RegattaServer --scratch-path "$scratch" "${optimize[@]}" --show-bin-path)"
server="$bin/RegattaServer"
loadclient="$bin/regatta-loadclient"

echo "== start Postgres"
start_postgres

# 1. account: the queue locks a minute after a join, so no fleet locks under a test that only joins and leaves.
start_server free QUEUE_LOCK_SECONDS=60 CATCH_FINISHERS=off
echo "== account: OnlineRaceUITests and OnlineAccountUITests against 127.0.0.1:$port"
phase_arguments=("${caller_arguments[@]+"${caller_arguments[@]}"}")
run_tests "" -only-testing:RegattaUITests/OnlineRaceUITests -only-testing:RegattaUITests/OnlineAccountUITests

# 2. The terms move on (#161): the same database, a server that asks for version 2.
stop_server
start_server free TERMS_VERSION=2 QUEUE_LOCK_SECONDS=60 CATCH_FINISHERS=off
echo "== terms-bump: OnlineAccountUITests against 127.0.0.1:$port"
arguments_for terms-bump
run_tests terms-bump -only-testing:RegattaUITests/OnlineAccountUITests/testServerRestartedWithANewTermsVersionAsksAgain

# 3. race (#162): a queue that locks in 4 s, a queue race that closes 12 s after its gun, and two minutes for a
# player who dropped out of a race alone to come back to it.
stop_server
start_server free QUEUE_LOCK_SECONDS=4 QUEUE_RACE_SECONDS=12 ALL_GONE_GRACE_SECONDS=120 CATCH_FINISHERS=off
echo "== race: OnlineQueueRaceUITests against 127.0.0.1:$port"
arguments_for race
run_tests race -only-testing:RegattaUITests/OnlineQueueRaceUITests

# 4. pair (#162): the app and a headless second person in one fleet. xcodebuild takes a minute or two to reach the
# test, so she doesn't join on the script's clock: the test arranges a race on the server as it taps Race online, and
# she joins as soon as /health shows it. The 75 s to the lock take either order of the two joins. The race closes
# 75 s after its gun: the test leaves it after the gun and queues again, and the close's rating push must come while
# she is queued. So she must be back in the queue before the close (run 40069036504: from the gun to Race online
# took her about 50 s, and a 30 s close came down while Leave race's confirm was up), and the close must come before
# her second queue locks, which it does with the lock no shorter than the race.
stop_server
start_server free QUEUE_LOCK_SECONDS=75 QUEUE_RACE_SECONDS=75 CATCH_FINISHERS=off
echo "== pair: OnlineQueueRaceUITests/testTwoHumansShareOneFleet with regatta-loadclient --queue-player 7001"
pair_port=$port
(
    wait_for_a_race "$pair_port" || exit 1
    echo "== pair: the second person joins the queue"
    exec "$loadclient" --host 127.0.0.1 --port "$pair_port" --queue-player 7001 --timeout 600 >> "$log" 2>&1
) &
helper_pid=$!
arguments_for pair no-retry
run_tests pair -only-testing:RegattaUITests/OnlineQueueRaceUITests/testTwoHumansShareOneFleet
kill "$helper_pid" 2>/dev/null || true
helper_pid=""

# 5. kill (#162): once the test's race is on the server and the app has had time to rejoin it (the test gives the
# cold launch 40 s to offer the rejoin), the server is killed and started again on the same port and database, where
# it cancels the race it finds orphaned.
stop_server
start_server free ALL_GONE_GRACE_SECONDS=120 CATCH_FINISHERS=off
kill_port=$port
(
    wait_for_a_race "$kill_port" || exit 1
    sleep 45
    echo "== kill: RegattaServer killed, and started again on 127.0.0.1:$kill_port"
    kill -9 "$server_pid" 2>/dev/null || true
    sleep 2
    env ENV=dev HOST=127.0.0.1 PORT="$kill_port" REGATTA_DATABASE_URL="$database_url" RACE_TOKEN_SECRET="$token_secret" \
        ALL_GONE_GRACE_SECONDS=120 CATCH_FINISHERS=off "$server" >> "$log" 2>&1
) &
killer_pid=$!
echo "== kill: OnlineQueueRaceUITests/testServerKilledMidRaceCancelsToHome against 127.0.0.1:$port"
arguments_for kill no-retry
run_tests kill -only-testing:RegattaUITests/OnlineQueueRaceUITests/testServerKilledMidRaceCancelsToHome
# The second server is the subshell's child: it goes with it.
pkill -P "$killer_pid" 2>/dev/null || true
kill "$killer_pid" 2>/dev/null || true
killer_pid=""

# 6. delete (#166): dev player 9166's queue race to the close, Delete my online data, a relaunch; then the database.
stop_server
start_server free QUEUE_LOCK_SECONDS=4 QUEUE_RACE_SECONDS=12 CATCH_FINISHERS=off
device_events_before="$(query "SELECT count(*) FROM analytics_events WHERE source = 'device'")"
echo "== delete: OnlineDeletionUITests against 127.0.0.1:$port"
arguments_for delete
run_tests delete -only-testing:RegattaUITests/OnlineDeletionUITests
check_deletion "$device_events_before"
echo "e2e.sh: passed"
