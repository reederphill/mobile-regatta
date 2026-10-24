#!/usr/bin/env bash
# The bot-suite workflow (.github/workflows/botsuite.yml, #105) sails in the pinned Linux replay image, the one
# scripts/linux-test.sh pins as IMAGE (changing it changes the simulation version), and the nightly persistence job
# (.github/workflows/nightly.yml, #144) tests the server's Postgres stores in it. Fails unless every container image
# botsuite.yml names, and every swift image nightly.yml names, is exactly that IMAGE, so the pins can't drift.
# nightly.yml runs it.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
image="$(sed -n 's/^IMAGE="\(.*\)"$/\1/p' "$root/scripts/linux-test.sh")"
[[ -n "$image" ]] || { echo "check-image-pins: no IMAGE=\"...\" line in scripts/linux-test.sh" >&2; exit 1; }
status=0

# check <workflow> <sed pattern of the pinned image lines>
check() {
    local workflow="$root/.github/workflows/$1" pins pin
    pins="$(sed -n "$2" "$workflow")"
    [[ -n "$pins" ]] || { echo "check-image-pins: no pinned container image in $workflow" >&2; status=1; return; }
    while IFS= read -r pin; do
        if [[ "$pin" != "$image" ]]; then
            echo "check-image-pins: $workflow pins $pin, scripts/linux-test.sh pins $image" >&2
            status=1
        fi
    done <<< "$pins"
}

check botsuite.yml 's/^ *image: *\([^ ]*\) *$/\1/p'
# nightly.yml also names service images (postgres): only its swift images are the replay platform's.
check nightly.yml 's/^ *image: *\(swift[:@][^ ]*\) *$/\1/p'
exit "$status"
