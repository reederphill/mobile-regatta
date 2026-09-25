# Shared by the scripts in this folder: source it.

# Runs "$@", killed after $1 seconds with SIGALRM (exit status 142). perl, since macOS has no timeout(1).
with_timeout() {
    local seconds=$1
    shift
    perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$seconds" "$@"
}

readonly TIMED_OUT=142

# Runs "$@" once it holds the lock file $1, killed after $2 seconds (exit status TIMED_OUT). The wait isn't
# timed. lockf(1) takes a flock that the kernel drops if the holder dies, so a killed run never strands it.
# Whoever holds it is written next to it, in $1.holder, for the next run's "waiting for" line.
run_locked() {
    local lock=$1 seconds=$2
    shift 2
    if ! lockf -s -t 0 "$lock" true; then
        echo "== waiting for $(basename "$lock"), held by $(cat "$lock.holder" 2>/dev/null || echo "another run")"
    fi
    lockf -k "$lock" perl -e '
        my ($holder, $file, $seconds) = splice @ARGV, 0, 3;
        if (open my $f, ">", $file) { print $f "$holder\n"; close $f }
        my $pid = fork // die "fork: $!\n";
        unless ($pid) { exec @ARGV or die "exec: $!\n" }
        $SIG{ALRM} = sub { kill "TERM", $pid; waitpid $pid, 0; exit 142 };
        alarm $seconds;
        waitpid $pid, 0;
        exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
    ' "${LOCK_HOLDER:-pid $$}" "$lock.holder" "$seconds" "$@"
}

# The machine-wide locks, shared by every worktree of the clone. One heavy build or package test run at a time
# (8 GB of RAM: two at once swap), and one app test run on the one simulator.
locks_dir() { (cd "$(git rev-parse --git-common-dir)" && pwd); }
