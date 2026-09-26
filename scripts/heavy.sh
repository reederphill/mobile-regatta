#!/usr/bin/env bash
# Runs one heavy command outside check.sh (a `swift test --filter` or `-only-testing` rerun, linux-test.sh)
# holding check.sh's machine-wide lock, so it doesn't swap against another worktree's build.
#
#   scripts/heavy.sh [--simulator] <command...>
#
# --simulator takes the simulator lock instead, for xcodebuild test runs. Killed after
# CHECK_STEP_TIMEOUT_MINUTES (default 15), not counting the wait.
set -euo pipefail

source "$(dirname "$0")/lib.sh"
lock=build
if [[ "${1:-}" == --simulator ]]; then
    lock=simulator
    shift
fi
(( $# )) || { echo "usage: scripts/heavy.sh [--simulator] <command...>" >&2; exit 2; }
LOCK_HOLDER="$(pwd) (pid $$): $*" run_locked "$(locks_dir)/check-$lock.lock" \
    $(( ${CHECK_STEP_TIMEOUT_MINUTES:-15} * 60 )) "$@"
