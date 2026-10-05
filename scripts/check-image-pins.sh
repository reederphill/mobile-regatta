#!/usr/bin/env bash
# The bot-suite workflow (.github/workflows/botsuite.yml, #105) sails in the pinned Linux replay image, the one
# scripts/linux-test.sh pins as IMAGE (changing it changes the simulation version). Fails unless every container image
# the workflow names is exactly that IMAGE, so the two pins can't drift. check.sh runs it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
image="$(sed -n 's/^IMAGE="\(.*\)"$/\1/p' "$root/scripts/linux-test.sh")"
[[ -n "$image" ]] || { echo "check-image-pins: no IMAGE=\"...\" line in scripts/linux-test.sh" >&2; exit 1; }
workflow="$root/.github/workflows/botsuite.yml"
pins="$(sed -n 's/^ *image: *\([^ ]*\) *$/\1/p' "$workflow")"
[[ -n "$pins" ]] || { echo "check-image-pins: no container image in $workflow" >&2; exit 1; }
status=0
while IFS= read -r pin; do
    if [[ "$pin" != "$image" ]]; then
        echo "check-image-pins: $workflow pins $pin, scripts/linux-test.sh pins $image" >&2
        status=1
    fi
done <<< "$pins"
exit "$status"
