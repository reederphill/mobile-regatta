#!/usr/bin/env bash
# The local gate, fastest failure first: compile every package the change reaches with its tests (and the
# app's tests, if it reaches the app), then run the packages' tests, then the app's unit tests. The golden and
# Linux run in CI before merge (scripts/linux-test.sh locally).
#
#   scripts/check.sh [--base <ref>] [--all] [--packages "<names>"] [--no-app] [--force]
#   scripts/check.sh --status [--rev <commit>] [--base <ref>] [--all] [--packages "<names>"] [--no-app]
#
# What a change reaches, from the files changed since its merge base with --base (default origin/main),
# committed or not: RegattaCore reaches every package, and the app through its sources; RegattaProtocol
# reaches RegattaClient and RegattaServer; RegattaClient reaches RegattaServer (its load client); RegattaProtocol
# and RegattaClient reach the app through their sources too (the online client, #68). --all
# checks everything; --packages names the packages instead (no app unless it changed); --no-app skips the app.
#
# Tests are built optimized (-O): the simulation runs about 15x faster than at -Onone, and the tests are mostly
# simulation. Debug and release digests are held equal in CI (check-digest-stable.sh, the Linux job).
#
# Each package builds into its own scratch directory, .build/check/<package>: SwiftPM keys its build plan on
# the scratch directory, not the root package, so packages sharing one ran another package's tests. After each
# package's tests, check.sh confirms that every one of its test targets ran.
#
# A passed test step is recorded under the git common dir (shared by every worktree of the clone), keyed by the
# content of what it depends on: its package and the packages below it (the app: its sources, tests and
# project, and the packages it links), check.sh itself, the Xcode version and, for the app, the destination.
# A step whose key has passed is skipped with its build, so a rebase or a commit elsewhere in the tree doesn't
# rerun it; --force reruns it. Each record keeps the names of the tests that passed, in
# check-passed/<key>.tests. --status prints what has passed for the working tree (or --rev's commit) without
# running anything, and exits 1 if anything the change reaches hasn't.
#
# Builds and package tests take the machine-wide build lock, and the app's tests the simulator lock, both in
# the git common dir: one of each at a time across every worktree. Each step is killed after
# CHECK_STEP_TIMEOUT_MINUTES (default 15), not counting the wait for its lock. The app runs on
# CHECK_DESTINATION (default the iPhone 17 simulator).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/lib.sh

usage="usage: scripts/check.sh [--status [--rev <commit>]] [--base <ref>] [--all] [--packages \"<names>\"] [--no-app] [--force]"
base=origin/main
all=0
force=0
no_app=0
status_only=0
rev=""
explicit=""
while (( $# )); do
    case "$1" in
        --base) base="$2"; shift ;;
        --all) all=1 ;;
        --packages) explicit="$2"; shift ;;
        --no-app) no_app=1 ;;
        --force) force=1 ;;
        --status) status_only=1 ;;
        --rev) rev="$2"; shift ;;
        *) echo "$usage" >&2; exit 2 ;;
    esac
    shift
done
if [[ -n "$rev" ]] && (( ! status_only )); then
    echo "check.sh: --rev goes with --status (the steps run on the working tree)" >&2
    exit 2
fi

scratch="$root/.build/check"
destination="${CHECK_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
step_seconds=$(( ${CHECK_STEP_TIMEOUT_MINUTES:-15} * 60 ))
optimize=(-Xswiftc -O)

# The tree checked: --rev's, or the working tree's, untracked files included, through a scratch index.
if [[ -n "$rev" ]]; then
    tree="$(git rev-parse --verify "$rev^{tree}")"
else
    index="$(mktemp)"
    trap 'rm -f "$index"' EXIT
    cp "$(git rev-parse --git-path index)" "$index"
    GIT_INDEX_FILE="$index" git add -A
    tree="$(GIT_INDEX_FILE="$index" git write-tree)"
fi
locks="$(locks_dir)"
records="$locks/check-passed"
mkdir -p "$records"

# The files the change touched: since the merge base, in the working tree, or up to --rev.
changed_files() {
    if [[ -n "$rev" ]]; then
        git diff --name-only "$merge_base" "$rev"
    else
        git diff --name-only "$merge_base"
        git ls-files --others --exclude-standard
    fi
}

core=0 protocol=0 client=0 server=0 app=0
if (( all )); then
    core=1 protocol=1 client=1 server=1 app=1
elif [[ -n "$explicit" ]]; then
    for package in $explicit; do
        case "$package" in
            RegattaCore) core=1 ;;
            RegattaProtocol) protocol=1 ;;
            RegattaClient) client=1 ;;
            RegattaServer) server=1 ;;
            *) echo "check.sh: unknown package $package" >&2; exit 2 ;;
        esac
    done
elif ! merge_base="$(git merge-base "$base" "${rev:-HEAD}" 2>/dev/null)"; then
    echo "check.sh: no merge base with $base; checking everything"
    core=1 protocol=1 client=1 server=1 app=1
else
    while IFS= read -r file; do
        case "$file" in
            scripts/check.sh | scripts/lib.sh) core=1 protocol=1 client=1 server=1 app=1 ;;
            Packages/RegattaCore/Sources/* | Packages/RegattaCore/Package.*) core=1 app=1 ;;
            Packages/RegattaCore/*) core=1 ;;
            Packages/RegattaProtocol/Sources/* | Packages/RegattaProtocol/Package.*) protocol=1 app=1 ;;
            Packages/RegattaProtocol/*) protocol=1 ;;
            Packages/RegattaClient/Sources/* | Packages/RegattaClient/Package.*) client=1 app=1 ;;
            Packages/RegattaClient/*) client=1 ;;
            Packages/RegattaServer/*) server=1 ;;
            Regatta/* | RegattaTests/* | RegattaUITests/* | Regatta.xcodeproj/*) app=1 ;;
        esac
    done < <(changed_files)
    (( core )) && protocol=1
    (( protocol )) && client=1 && server=1
    (( client )) && server=1
fi
(( no_app )) && app=0

packages=()
(( core )) && packages+=(RegattaCore)
(( protocol )) && packages+=(RegattaProtocol)
(( client )) && packages+=(RegattaClient)
(( server )) && packages+=(RegattaServer)

if (( ${#packages[@]} == 0 && ! app )); then
    echo "check.sh: nothing to check"
    exit 0
fi
echo "check.sh: tree $tree; packages: ${packages[*]:-none}; app: $( (( app )) && echo yes || echo no )"

# What each unit's tests depend on, as paths in the tree. The app links RegattaCore, RegattaProtocol and
# RegattaClient; its unit tests read RegattaUITests/Fixtures and the app's sources.
inputs() {
    case "$1" in
        RegattaCore) echo Packages/RegattaCore ;;
        RegattaProtocol) echo Packages/RegattaCore Packages/RegattaProtocol ;;
        RegattaClient) echo Packages/RegattaCore Packages/RegattaProtocol Packages/RegattaClient ;;
        RegattaServer) echo Packages ;;
        app) echo Regatta RegattaTests RegattaUITests Regatta.xcodeproj ThirdParty \
                  Packages/RegattaCore Packages/RegattaProtocol Packages/RegattaClient ;;
    esac
}
toolchain="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"

# The record key of a unit's test step: the hash of everything the step's result depends on.
key() {
    local unit=$1 path
    {
        echo "test $unit"
        echo "$toolchain"
        [[ "$unit" == app ]] && echo "$destination"
        for path in scripts/check.sh scripts/lib.sh $(inputs "$unit"); do
            echo "$path $(git rev-parse -q --verify "$tree:$path" 2>/dev/null || echo absent)"
        done
    } | git hash-object --stdin
}
passed() { (( ! force )) && [[ -f "$records/$(key "$1")" ]]; }

units=(${packages[@]+"${packages[@]}"})
(( app )) && units+=(app)

if (( status_only )); then
    missing=0
    for unit in "${units[@]}"; do
        if passed "$unit"; then
            echo "passed   test $unit ($(wc -l < "$records/$(key "$unit").tests" | tr -d ' ') tests: $records/$(key "$unit").tests)"
        else
            echo "not run  test $unit"
            missing=1
        fi
    done
    exit "$missing"
fi

export LOCK_HOLDER="$root (pid $$)"
app_build=(xcodebuild -project Regatta.xcodeproj -scheme Regatta -destination "$destination"
           -derivedDataPath "$scratch/DerivedData" -only-testing:RegattaTests -quiet
           SWIFT_OPTIMIZATION_LEVEL=-O)

# Runs one step holding the named lock; exits on failure.
step() {
    local label=$1 lock=$2
    shift 2
    echo "== $label"
    local start=$SECONDS status=0
    LOCK_HOLDER="$LOCK_HOLDER: $label" run_locked "$locks/check-$lock.lock" "$step_seconds" "$@" || status=$?
    if (( status == TIMED_OUT )); then
        echo "check.sh: $label timed out after $step_seconds s" >&2
    fi
    if (( status != 0 )); then
        echo "check.sh: FAIL $label" >&2
        exit "$status"
    fi
    echo "== PASS $label ($((SECONDS - start)) s)"
}

# Records a unit's passed test step with the names of the tests that ran.
record() {
    local unit=$1 tests=$2 k
    k="$(key "$unit")"
    cp "$tests" "$records/$k.tests"
    printf 'test %s\ntree %s\n' "$unit" "$tree" > "$records/$k"
}

# The test names in a Swift Testing xUnit report, one "Target.Suite/test" per line.
xunit_tests() {
    perl -ne 'while (/<testcase classname="([^"]*)" name="([^"]*)"/g) { print "$1/$2\n" }' "$@" | sort -u
}

# Fails unless every test target of the package ran: a test target is a folder under Tests/ with Swift files.
check_targets_ran() {
    local package=$1 tests=$2 target missing=0
    for target in Packages/"$package"/Tests/*/; do
        target="$(basename "$target")"
        compgen -G "Packages/$package/Tests/$target/*.swift" > /dev/null || continue
        if ! grep -q "^$target\." "$tests"; then
            echo "check.sh: no test of $package's $target ran" >&2
            missing=1
        fi
    done
    return "$missing"
}

todo=()
for unit in "${units[@]}"; do
    if passed "$unit"; then
        echo "== test $unit: passed before on this content, skipped with its build"
    else
        todo+=("$unit")
    fi
done
if (( ${#todo[@]} == 0 )); then
    echo "check.sh: all passed"
    exit 0
fi

reports="$(mktemp -d)"
trap 'rm -rf "$reports" ${index:+"$index"}' EXIT

for unit in "${todo[@]}"; do
    if [[ "$unit" == app ]]; then
        step "build app tests" build "${app_build[@]}" build-for-testing
    else
        step "build $unit" build swift build --build-tests --package-path "Packages/$unit" \
            --scratch-path "$scratch/$unit" "${optimize[@]}"
    fi
done
for unit in "${todo[@]}"; do
    [[ "$unit" == app ]] && continue
    step "test $unit" build swift test --package-path "Packages/$unit" --scratch-path "$scratch/$unit" \
        "${optimize[@]}" --xunit-output "$reports/$unit.xml"
    xunit_tests "$reports/$unit"*.xml > "$reports/$unit.tests"
    check_targets_ran "$unit" "$reports/$unit.tests" || { echo "check.sh: FAIL test $unit" >&2; exit 1; }
    record "$unit" "$reports/$unit.tests"
done
if [[ " ${todo[*]} " == *" app "* ]]; then
    step "test app" simulator "${app_build[@]}" test-without-building -resultBundlePath "$reports/app.xcresult"
    xcrun xcresulttool get test-results tests --path "$reports/app.xcresult" | python3 -c '
import json, sys
def walk(node, suite):
    if node.get("nodeType") == "Test Case":
        print(suite + "/" + node["name"])
    for child in node.get("children", []):
        walk(child, node["name"] if node.get("nodeType") == "Test Suite" else suite)
for node in json.load(sys.stdin)["testNodes"]:
    walk(node, "")
' | sort -u > "$reports/app.tests"
    record app "$reports/app.tests"
fi
echo "check.sh: all passed"
