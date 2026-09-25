#!/usr/bin/env bash
# The local gate, fastest failure first: compile every package the change reaches with its tests (and the
# app's tests, if it reaches the app), then run the packages' tests, then the app's unit tests. The golden and
# Linux run in CI before merge (scripts/linux-test.sh locally).
#
#   scripts/check.sh [--base <ref>] [--all] [--packages "<names>"] [--no-app] [--force]
#
# What a change reaches, from the files changed since its merge base with --base (default origin/main),
# committed or not: RegattaCore reaches every package, and the app through its sources; RegattaProtocol
# reaches RegattaClient and RegattaServer; RegattaClient reaches RegattaServer (its load client); RegattaProtocol
# and RegattaClient reach the app through their sources too (the online client, #68). --all
# checks everything; --packages names the packages instead (no app unless it changed); --no-app skips the app.
#
# Every package builds into one scratch directory, .build/check, so shared dependencies build once.
# Each passed step is recorded against the tree it ran on, in check-passed/<tree hash> under the git common
# dir (shared by every worktree of the clone, so an agent in another worktree sees it), and is skipped when
# that tree is checked again; --force reruns it. Each step is killed after
# CHECK_STEP_TIMEOUT_MINUTES (default 15). The app runs on CHECK_DESTINATION (default the iPhone 17 simulator).
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
source scripts/lib.sh

base=origin/main
all=0
force=0
no_app=0
explicit=""
while (( $# )); do
    case "$1" in
        --base) base="$2"; shift ;;
        --all) all=1 ;;
        --packages) explicit="$2"; shift ;;
        --no-app) no_app=1 ;;
        --force) force=1 ;;
        *) echo "usage: scripts/check.sh [--base <ref>] [--all] [--packages \"<names>\"] [--no-app] [--force]" >&2; exit 2 ;;
    esac
    shift
done

scratch="$root/.build/check"
destination="${CHECK_DESTINATION:-platform=iOS Simulator,name=iPhone 17}"
step_seconds=$(( ${CHECK_STEP_TIMEOUT_MINUTES:-15} * 60 ))

# The working tree as a tree hash, untracked files included, through a scratch index.
index="$(mktemp)"
trap 'rm -f "$index"' EXIT
cp "$(git rev-parse --git-path index)" "$index"
GIT_INDEX_FILE="$index" git add -A
tree="$(GIT_INDEX_FILE="$index" git write-tree)"
records="$(cd "$(git rev-parse --git-common-dir)" && pwd)/check-passed"
passed="$records/$tree"
mkdir -p "$records"

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
elif ! merge_base="$(git merge-base "$base" HEAD 2>/dev/null)"; then
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
    done < <(git diff --name-only "$merge_base"; git ls-files --others --exclude-standard)
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

app_build=(xcodebuild -project Regatta.xcodeproj -scheme Regatta -destination "$destination"
           -derivedDataPath "$scratch/DerivedData" -only-testing:RegattaTests -quiet)

# Runs one step unless this tree already passed it, and records it when it passes.
step() {
    local label=$1
    shift
    if (( ! force )) && grep -qxF "$label" "$passed" 2>/dev/null; then
        echo "== $label: passed before on this tree, skipped"
        return
    fi
    echo "== $label"
    local start=$SECONDS status=0
    with_timeout "$step_seconds" "$@" || status=$?
    if (( status == TIMED_OUT )); then
        echo "check.sh: $label timed out after $step_seconds s" >&2
    fi
    if (( status != 0 )); then
        echo "check.sh: FAIL $label" >&2
        exit "$status"
    fi
    echo "$label" >> "$passed"
    echo "== PASS $label ($((SECONDS - start)) s)"
}

for package in ${packages[@]+"${packages[@]}"}; do
    step "build $package" swift build --build-tests --package-path "Packages/$package" --scratch-path "$scratch"
done
(( app )) && step "build app tests" "${app_build[@]}" build-for-testing
for package in ${packages[@]+"${packages[@]}"}; do
    step "test $package" swift test --package-path "Packages/$package" --scratch-path "$scratch"
done
(( app )) && step "test app" "${app_build[@]}" test-without-building
echo "check.sh: all passed"
