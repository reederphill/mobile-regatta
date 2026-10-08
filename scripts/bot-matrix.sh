#!/usr/bin/env bash
# The bot matrix for a ticket (validation.md): sails regatta-botsuite on this worktree's branch, compares it with main's
# baseline, and prints a gate and metric diff table.
#
#   scripts/bot-matrix.sh [regatta-botsuite options...]     e.g. --profile-mix live --tier-mix national --seeds 16
#
# The options are regatta-botsuite's (--profile-mix, --tier-mix, --seeds, --jobs, ...), all but --json, which this
# script sets. The baseline is the merge-base of HEAD and origin/main, sailed with the same options, and cached for every
# worktree of the clone in
#
#   $(git rev-parse --git-common-dir)/botsuite-baselines/<merge-base sha>/<args hash>.json   (and .txt, .args)
#
# The args hash covers the options that change results (all but --jobs), the contents of a --matrix or --thresholds
# file, and the platform (a race is the same only on one platform). With no baseline for that SHA and hash, the
# merge-base is built in a temporary detached worktree (removed after) and sailed once. Builds and runs go through
# scripts/heavy.sh, one heavy job on the machine at a time; each run is killed after BOT_MATRIX_TIMEOUT_MINUTES
# (default 240), not counting the wait for the lock.
#
# The branch's report lands in .build/bot-matrix/branch.{json,txt} at the worktree's root. Exits with the branch run's
# gate status (0 pass, 1 miss), 2 on a usage or setup error. --no-fetch skips `git fetch origin main`.
# Clear the cache with: rm -rf "$(git rev-parse --git-common-dir)/botsuite-baselines"
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"
root=$(pwd)
scripts="$root/scripts"
package=Packages/RegattaCore
export CHECK_STEP_TIMEOUT_MINUTES=${BOT_MATRIX_TIMEOUT_MINUTES:-240}

fetch=1
args=()
key_args=()  # the options that change results, in order: what the args hash covers
while (( $# )); do
    case "$1" in
        --no-fetch) fetch=0; shift ;;
        --json) echo "bot-matrix.sh: --json is set by the script" >&2; exit 2 ;;
        --jobs)
            (( $# >= 2 )) || { echo "bot-matrix.sh: --jobs needs a value" >&2; exit 2; }
            args+=("$1" "$2"); shift 2 ;;
        --matrix|--thresholds)
            (( $# >= 2 )) || { echo "bot-matrix.sh: $1 needs a value" >&2; exit 2; }
            [[ -f "$2" ]] || { echo "bot-matrix.sh: $1: no file $2" >&2; exit 2; }
            path=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
            args+=("$1" "$path")
            key_args+=("$1" "sha256:$(shasum -a 256 "$path" | cut -d' ' -f1)")
            shift 2 ;;
        *) args+=("$1"); key_args+=("$1"); shift ;;
    esac
done

if (( fetch )); then git fetch -q origin main || echo "bot-matrix.sh: git fetch failed; using the local origin/main" >&2; fi
base=$(git merge-base HEAD origin/main)
args_text="platform=$(uname -sm)"$'\n'"args=${key_args[*]:-}"
hash=$(printf '%s' "$args_text" | shasum -a 256 | cut -c1-16)
cache_dir="$(cd "$(git rev-parse --git-common-dir)" && pwd)/botsuite-baselines/$base"
baseline="$cache_dir/$hash.json"
out="$root/.build/bot-matrix"
mkdir -p "$out" "$cache_dir"

# Builds regatta-botsuite in the package at $1 and runs it with the options, the JSON report to $2 and the text to $3.
# Never fails on the gate: returns the run's exit status.
sail() {
    local dir=$1 json=$2 text=$3 bin status=0
    # set -e is off in a function called with ||: check the build by hand.
    "$scripts/heavy.sh" swift build -c release --package-path "$dir/$package" --product regatta-botsuite \
        || { echo "bot-matrix.sh: the build in $dir failed" >&2; exit 2; }
    bin=$(swift build -c release --package-path "$dir/$package" --show-bin-path)
    local start=$SECONDS
    "$scripts/heavy.sh" "$bin/regatta-botsuite" ${args[@]+"${args[@]}"} --json "$json" > "$text" 2>&1 || status=$?
    echo "== sailed in $(( SECONDS - start )) s (including any wait for the lock), exit $status"
    if (( status > 1 )); then
        cat "$text" >&2
        echo "bot-matrix.sh: regatta-botsuite failed (exit $status)" >&2
        exit 2
    fi
    return "$status"
}

if [[ -f "$baseline" ]]; then
    echo "== main baseline: cache hit for ${base:0:12} ($baseline); skipping main's build"
else
    echo "== main baseline: no cache for ${base:0:12}, args hash $hash; building it in a temporary worktree"
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/bot-matrix-base.XXXXXX")
    cleanup() { git -C "$root" worktree remove --force "$tmp/main" 2>/dev/null || true; rm -rf "$tmp"; }
    trap cleanup EXIT
    git worktree add -q --detach "$tmp/main" "$base"
    sail "$tmp/main" "$tmp/base.json" "$tmp/base.txt" || true
    cp "$tmp/base.txt" "$cache_dir/$hash.txt"
    printf '%s\nbase=%s\n' "$args_text" "$base" > "$cache_dir/$hash.args"
    mv "$tmp/base.json" "$baseline.partial" && mv "$baseline.partial" "$baseline"  # whole or absent
    cleanup
    trap - EXIT
    echo "== main baseline stored: $baseline"
fi

branch_status=0
if [[ "$(git rev-parse HEAD)" == "$base" && -z "$(git status --porcelain -- "$package")" ]]; then
    echo "== the branch is main's merge-base with no package changes: its run is the baseline"
    cp "$baseline" "$out/branch.json"
    cp "$cache_dir/$hash.txt" "$out/branch.txt"
    python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["passed"] else 1)' "$out/branch.json" \
        || branch_status=$?
else
    echo "== branch $(git rev-parse --short HEAD): sailing"
    sail "$root" "$out/branch.json" "$out/branch.txt" || branch_status=$?
fi
echo "== branch report: $out/branch.txt"

python3 - "$baseline" "$out/branch.json" <<'PY'
import json, re, sys

main, branch = (json.load(open(p)) for p in sys.argv[1:3])

def gate(breach):
    """A breach's gate: its text up to the first number ("national: finish share 0.80 < 0.90" -> "national: finish share")."""
    return re.split(r"\s+-?\d", breach, maxsplit=1)[0]

print(f"\ngates (main {'pass' if main['passed'] else 'FAIL'}, branch {'pass' if branch['passed'] else 'FAIL'})")
main_red = {gate(b): b for b in main["breaches"]}
branch_red = {gate(b): b for b in branch["breaches"]}
regressed = []
rows = []
for name in sorted(set(main_red) | set(branch_red)):
    m, b = name in main_red, name in branch_red
    flag = ""
    if b and not m:
        flag = "  << RED ON BRANCH ONLY" + (" (tick times: machine load, not the bots)" if name.startswith("tick:") else "")
        if not name.startswith("tick:"):
            regressed.append(name)
    elif m and not b:
        flag = "  (fixed on branch)"
    rows.append((name, "red" if m else "green", "red" if b else "green", flag))
if rows:
    w = max(len(r[0]) for r in rows)
    print(f"  {'gate':<{w}}  {'main':<5}  {'branch':<6}")
    for name, m, b, flag in rows:
        print(f"  {name:<{w}}  {m:<5}  {b:<6}{flag}")
        print(f"  {'':<{w}}    main: {main_red.get(name, '-')} | branch: {branch_red.get(name, '-')}")
else:
    print("  every gate green on both")

SKIP = {"races", "matrix", "thresholds", "breaches", "passed", "simulationVersion"}
def leaves(node, path=""):
    if isinstance(node, bool):
        return
    if isinstance(node, (int, float)):
        yield path, node
    elif isinstance(node, dict):
        for k in sorted(node):
            if not path and k in SKIP:
                continue
            yield from leaves(node[k], f"{path}.{k}" if path else k)

mv, bv = dict(leaves(main)), dict(leaves(branch))
changed = []
for key in sorted(set(mv) | set(bv)):
    a, b = mv.get(key), bv.get(key)
    if a == b:
        continue
    changed.append((key, a, b))
fmt = lambda v: "-" if v is None else (f"{v:.4g}" if isinstance(v, float) else str(v))
print(f"\nmetrics: {len(changed)} changed of {len(set(mv) | set(bv))} (timings.* are tick times: machine load, not the bots)")
if changed:
    w = max(len(k) for k, _, _ in changed)
    print(f"  {'metric':<{w}}  {'main':>10}  {'branch':>10}  {'delta':>10}")
    for key, a, b in changed:
        delta = fmt(b - a) if a is not None and b is not None else "-"
        if delta not in ("-",) and not delta.startswith("-"):
            delta = "+" + delta
        print(f"  {key:<{w}}  {fmt(a):>10}  {fmt(b):>10}  {delta:>10}")
if regressed:
    print(f"\nREGRESSED: {len(regressed)} gate(s) green on main are red on the branch: {', '.join(regressed)}")
PY

exit "$branch_status"
