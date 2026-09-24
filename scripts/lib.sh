# Shared by the scripts in this folder: source it.

# Runs "$@", killed after $1 seconds with SIGALRM (exit status 142). perl, since macOS has no timeout(1).
with_timeout() {
    local seconds=$1
    shift
    perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' "$seconds" "$@"
}

readonly TIMED_OUT=142
