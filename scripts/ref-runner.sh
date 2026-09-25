#!/usr/bin/env bash
# The benchmark's reference runner (#69): a Hetzner Cloud server of the reference type in Ashburn, created
# for one benchmark session and deleted after it (docs/prerequisites.md, Hosting: nothing runs all the time
# before launch).
#
#   scripts/ref-runner.sh up     create the server; its cloud-init installs Swift and registers an ephemeral
#                                GitHub Actions runner labelled `regatta-ref`, which takes one job
#   scripts/ref-runner.sh down   delete the server and its runner
#
# Then start the Bench workflow (.github/workflows/bench.yml) by hand. The runner is ephemeral, so each
# further run needs `down` and `up` again.
#
# Needs the hcloud CLI with HCLOUD_TOKEN set, the gh CLI signed in with admin access to the repository (the
# runner registration token comes from `gh api`), and jq.
#
# Settings (environment):
#   HCLOUD_TOKEN          Hetzner Cloud API token (required)
#   REF_SERVER_TYPE       server type; by default the cheapest shared-vCPU x86 type Hetzner offers in
#                         REF_LOCATION, looked up with `hcloud server-type list` rather than hardcoded
#   REF_LOCATION          default ash (Ashburn, Virginia)
#   REF_SERVER_NAME       server and runner name, default regatta-ref
#   REF_IMAGE             default ubuntu-24.04
#   REF_SSH_KEY           an hcloud SSH key name or ID to install (optional; without one Hetzner emails a
#                         root password)
#   REF_REPO              default reederphill/mobile-regatta
#   REF_SWIFT_VERSION     default 6.3.3, the Linux replay platform's toolchain (scripts/linux-test.sh IMAGE)
#   REF_RUNNER_WAIT_MINUTES  how long `up` waits for the runner to come online, default 15
#
# `up` prints the server type and its price: record both in docs/prerequisites.md, Hosting, the first time.
set -euo pipefail

usage() {
    sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2
    exit 2
}

[[ $# -eq 1 ]] || usage
command="$1"
[[ "$command" == up || "$command" == down ]] || usage

LOCATION="${REF_LOCATION:-ash}"
NAME="${REF_SERVER_NAME:-regatta-ref}"
IMAGE="${REF_IMAGE:-ubuntu-24.04}"
REPO="${REF_REPO:-reederphill/mobile-regatta}"
SWIFT_VERSION="${REF_SWIFT_VERSION:-6.3.3}"
LABEL="regatta-ref"

fail() {
    echo "ref-runner.sh: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "needs the $1 CLI ($2)"
}

need hcloud "https://github.com/hetznercloud/cli"
need gh "https://cli.github.com"
need jq "https://jqlang.org"
[[ -n "${HCLOUD_TOKEN:-}" ]] || fail "set HCLOUD_TOKEN to a Hetzner Cloud API token (read & write)"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in (gh auth login)"

# The runner's ID by name, or nothing.
runner_id() {
    gh api "repos/$REPO/actions/runners" --paginate \
        --jq ".runners[] | select(.name == \"$NAME\") | .id"
}

# The cheapest shared-vCPU x86 server type with a price in $LOCATION, and that price, as JSON.
reference_type() {
    hcloud server-type list -o json | jq --arg location "$LOCATION" '
        [ .[]
          | select(.cpu_type == "shared" and .architecture == "x86" and ((.deprecated // false) | not))
          | . as $type
          | ($type.prices[] | select(.location == $location)) as $price
          | { name: $type.name, cores: $type.cores, memory: $type.memory, disk: $type.disk,
              monthly: $price.price_monthly.gross, hourly: $price.price_hourly.gross } ]
        | sort_by(.monthly | tonumber) | first'
}

up() {
    if hcloud server describe "$NAME" >/dev/null 2>&1; then
        fail "server $NAME already exists; run scripts/ref-runner.sh down first"
    fi

    local type
    if [[ -n "${REF_SERVER_TYPE:-}" ]]; then
        type="$(hcloud server-type list -o json | jq --arg name "$REF_SERVER_TYPE" --arg location "$LOCATION" '
            [ .[] | select(.name == $name) | . as $type
              | ($type.prices[] | select(.location == $location)) as $price
              | { name: $type.name, cores: $type.cores, memory: $type.memory, disk: $type.disk,
                  monthly: $price.price_monthly.gross, hourly: $price.price_hourly.gross } ] | first')"
    else
        type="$(reference_type)"
    fi
    [[ "$type" != null && -n "$type" ]] || fail "no server type ${REF_SERVER_TYPE:-(shared x86)} priced in $LOCATION"
    local server_type
    server_type="$(jq -r .name <<< "$type")"

    local token runner_version
    token="$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)"
    [[ -n "$token" ]] || fail "no runner registration token for $REPO (needs admin access)"
    runner_version="$(gh api repos/actions/runner/releases/latest --jq .tag_name)"
    runner_version="${runner_version#v}"

    # cloud-init runs this as root on first boot. The registration token in it expires after an hour; no -x,
    # so it stays out of the server's cloud-init log.
    user_data="$(mktemp)"
    trap 'rm -f "$user_data"' EXIT
    cat > "$user_data" <<EOF
#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Swift's Linux dependencies (swift.org, Ubuntu 24.04), and git for actions/checkout.
apt-get install -y binutils curl git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev \
    libncurses-dev libpython3-dev libsqlite3-0 libstdc++-13-dev libxml2-dev libz3-dev pkg-config \
    python3-lib2to3 tzdata unzip zlib1g-dev
swift="swift-$SWIFT_VERSION-RELEASE"
curl -fsSL "https://download.swift.org/swift-$SWIFT_VERSION-release/ubuntu2404/\$swift/\$swift-ubuntu24.04.tar.gz" \
    | tar -xz -C /opt
ln -sf "/opt/\$swift-ubuntu24.04/usr/bin/"* /usr/local/bin/
swift --version

useradd --create-home --shell /bin/bash runner
mkdir -p /home/runner/actions-runner
cd /home/runner/actions-runner
curl -fsSL "https://github.com/actions/runner/releases/download/v$runner_version/actions-runner-linux-x64-$runner_version.tar.gz" \
    | tar -xz
./bin/installdependencies.sh
chown -R runner:runner /home/runner
sudo -u runner ./config.sh --unattended --ephemeral --url "https://github.com/$REPO" --token "$token" \
    --name "$NAME" --labels "$LABEL" --replace
./svc.sh install runner
./svc.sh start
EOF

    echo "Creating $NAME: $server_type in $LOCATION ($IMAGE)"
    local args=(--name "$NAME" --type "$server_type" --location "$LOCATION" --image "$IMAGE"
                --user-data-from-file "$user_data" --label "purpose=$LABEL")
    [[ -n "${REF_SSH_KEY:-}" ]] && args+=(--ssh-key "$REF_SSH_KEY")
    hcloud server create "${args[@]}"

    echo "Waiting for runner $NAME to come online (cloud-init installs Swift and the runner)..."
    local deadline=$((SECONDS + ${REF_RUNNER_WAIT_MINUTES:-15} * 60)) status=""
    while (( SECONDS < deadline )); do
        status="$(gh api "repos/$REPO/actions/runners" --paginate \
            --jq ".runners[] | select(.name == \"$NAME\") | .status" || true)"
        [[ "$status" == online ]] && break
        sleep 20
    done
    if [[ "$status" == online ]]; then
        echo "Runner $NAME is online with label $LABEL: start the Bench workflow (Actions > Bench > Run workflow)."
    else
        echo "ref-runner.sh: runner $NAME not online yet; check the server's /var/log/cloud-init-output.log" >&2
    fi

    echo
    echo "Reference plan (record in docs/prerequisites.md, Hosting, the first time):"
    jq -r '"  \(.name): \(.cores) shared x86 vCPU, \(.memory) GB RAM, \(.disk) GB disk; " +
           "\(.monthly | tonumber * 100 | round / 100) a month, \(.hourly | tonumber * 10000 | round / 10000) an hour (gross, EUR or USD per the account)"' \
        <<< "$type"
    echo "  location $LOCATION"
    echo "Delete it with scripts/ref-runner.sh down when the benchmark is done."
}

down() {
    if hcloud server describe "$NAME" >/dev/null 2>&1; then
        hcloud server delete "$NAME"
    else
        echo "No server $NAME."
    fi
    local id
    for id in $(runner_id); do
        gh api -X DELETE "repos/$REPO/actions/runners/$id"
        echo "Removed runner $NAME ($id)."
    done
}

"$command"
