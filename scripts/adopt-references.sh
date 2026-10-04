#!/usr/bin/env bash
# Adopts CI's renders as the render-fixture references (#215). When a reference compare fails in CI (or a
# reference is missing), the render job uploads the render as the render-actuals artifact. This downloads it,
# copies each <device>/<name>.png into RegattaUITests/References/<device>/, and prints what changed. Look at
# the renders (the artifact also holds each <name>-diff.png), commit them, and the next CI run compares against
# them. References come from CI, never from a local simulator run (docs/agents/validation.md).
#
#   scripts/adopt-references.sh <PR number>      the ci.yml run for the pull request's head commit
#   scripts/adopt-references.sh --pr <PR number>
#   scripts/adopt-references.sh --run <run id>   a given run (ci.yml's is the one the references are pinned
#                                                to: iPhone 17, iOS 26.5); a bare number of 8 or more digits
#                                                is taken as a run id too
#
# The artifact is uploaded only when the render job fails, and kept 5 days. Needs the gh CLI signed in; the
# repository is this checkout's (or GH_REPO). Exits 1 when there's nothing to adopt, 2 on a usage error.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

references="RegattaUITests/References"
artifact="render-actuals"
usage="usage: scripts/adopt-references.sh <PR number> | --pr <PR number> | --run <run id>"

pr="" run=""
case "${1:-}" in
    -h | --help) echo "$usage"; exit 0 ;;
    --pr) (( $# == 2 )) || { echo "$usage" >&2; exit 2; }; pr="$2" ;;
    --run) (( $# == 2 )) || { echo "$usage" >&2; exit 2; }; run="$2" ;;
    *)
        (( $# == 1 )) || { echo "$usage" >&2; exit 2; }
        if (( ${#1} >= 8 )); then run="$1"; else pr="$1"; fi
        ;;
esac
if [[ ! "$pr$run" =~ ^[0-9]+$ ]]; then
    echo "adopt-references.sh: '$pr$run' isn't a PR number or a run id" >&2
    echo "$usage" >&2
    exit 2
fi

if [[ -n "$pr" ]]; then
    head="$(gh pr view "$pr" --json headRefName,headRefOid --jq '"\(.headRefName) \(.headRefOid)"')"
    branch="${head% *}" sha="${head##* }"
    run="$(gh run list --workflow ci.yml --commit "$sha" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
    if [[ -z "$run" ]]; then
        echo "adopt-references.sh: PR #$pr's head ($branch @ ${sha:0:7}) has no ci.yml run yet" >&2
        exit 1
    fi
    echo "== PR #$pr ($branch @ ${sha:0:7}): ci.yml run $run"
fi

# Green runs upload nothing (the upload step runs on failure only), and artifacts expire.
expired="$(gh api "repos/{owner}/{repo}/actions/runs/$run/artifacts?name=$artifact" \
    --jq '[.artifacts[] | .expired | tostring] | join(" ")')"
if [[ -z "$expired" ]]; then
    echo "adopt-references.sh: run $run has no $artifact artifact: no reference compare failed there, or its render" >&2
    echo "job hasn't finished yet. Nothing to adopt." >&2
    exit 1
fi
if [[ " $expired " != *" false "* ]]; then
    echo "adopt-references.sh: run $run's $artifact artifact has expired (kept 5 days). Rerun its failed jobs" >&2
    echo "(gh run rerun $run --failed) for a fresh one." >&2
    exit 1
fi

download="$(mktemp -d -t regatta-render-actuals)"
trap 'rm -rf "$download"' EXIT
echo "== download $artifact from run $run"
gh run download "$run" --name "$artifact" --dir "$download"

# <device>/<name>.png is a render, at the path its reference has under References/; <name>-diff.png is its diff,
# which is never adopted.
adopted=0
while IFS= read -r -d '' png; do
    name="$(basename "$png")"
    [[ "$name" == *-diff.png ]] && continue
    folder="$(dirname "$png")"
    if [[ "$folder" == "$download" ]]; then
        echo "adopt-references.sh: skipping $name: not in a <device>/ folder" >&2
        continue
    fi
    device="$(basename "$folder")"
    mkdir -p "$references/$device"
    cp "$png" "$references/$device/$name"
    echo "adopted $device/$name"
    adopted=$((adopted + 1))
done < <(find "$download" -type f -name '*.png' -print0 | sort -z)

if (( adopted == 0 )); then
    echo "adopt-references.sh: run $run's $artifact artifact holds no renders to adopt" >&2
    exit 1
fi

echo "== $references"
if [[ -z "$(git status --porcelain -- "$references")" ]]; then
    echo "unchanged: the renders are the committed references byte for byte, so there's nothing to commit"
    exit 0
fi
git status --short -- "$references"
git diff --stat -- "$references"
echo "Look at the renders, then commit $references; the next CI run compares against them."
