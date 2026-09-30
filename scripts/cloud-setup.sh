#!/usr/bin/env bash
# Sets up a Linux cloud session (Ubuntu 24.04, x86_64: the replay platform's OS and architecture) to build and
# test the pure-Swift packages natively, with no container: installs the Swift toolchain that
# scripts/linux-test.sh pins and puts it on PATH. Idempotent; safe as an environment setup script.
#
#   scripts/cloud-setup.sh            install (if missing) and resolve dependencies
#   scripts/cloud-setup.sh --check    print what is installed, install nothing
#
# Then, per package (the app, SpriteKit and the UI tests are macOS-only and stay in CI):
#   swift test --package-path Packages/RegattaCore --scratch-path .build/check/RegattaCore -Xswiftc -O
# The golden and RegattaBots digests are CI's job (docs/agents/validation.md): a native run here is a fast
# signal, not the replay platform. scripts/check.sh is written for the Mac; on Linux run the swift test line above per package.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# Keep in step with IMAGE in scripts/linux-test.sh.
version="$(grep -o 'swift:[0-9.]*-noble' "$root/scripts/linux-test.sh" | head -1 | sed 's/swift:\(.*\)-noble/\1/')"
prefix="${SWIFT_PREFIX:-/opt/swift-$version}"

if [[ "${1:-}" == --check ]]; then
    echo "want swift $version at $prefix"
    "$prefix/usr/bin/swift" --version 2>&1 || echo "not installed"
    exit 0
fi

[[ "$(uname -s)-$(uname -m)" == Linux-x86_64 ]] || { echo "cloud-setup.sh: needs Linux x86_64" >&2; exit 1; }

if [[ ! -x "$prefix/usr/bin/swift" ]]; then
    sudo=""; [[ "$(id -u)" != 0 ]] && sudo=sudo
    $sudo apt-get update -qq
    DEBIAN_FRONTEND=noninteractive $sudo apt-get install -y -qq --no-install-recommends \
        binutils git gnupg2 libc6-dev libcurl4-openssl-dev libedit2 libgcc-13-dev libpython3-dev \
        libsqlite3-0 libstdc++-13-dev libxml2-dev libncurses-dev libz3-dev pkg-config tzdata \
        unzip zlib1g-dev ca-certificates curl
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    url="https://download.swift.org/swift-$version-release/ubuntu2404/swift-$version-RELEASE/swift-$version-RELEASE-ubuntu24.04.tar.gz"
    curl -fsSL --retry 4 -o "$tmp/swift.tar.gz" "$url"
    $sudo mkdir -p "$prefix"
    $sudo tar -xzf "$tmp/swift.tar.gz" -C "$prefix" --strip-components=1
fi

# PATH for this shell's children and for later sessions.
line="export PATH=\"$prefix/usr/bin:\$PATH\""
grep -qxF "$line" "$HOME/.bashrc" 2>/dev/null || echo "$line" >> "$HOME/.bashrc"
export PATH="$prefix/usr/bin:$PATH"
swift --version

# Resolve dependencies (swift-crypto) once, per package, each with its own scratch dir (see linux-test.sh).
for p in RegattaCore RegattaProtocol RegattaClient RegattaServer; do
    swift package --package-path "$root/Packages/$p" --scratch-path "$root/.build/check/$p" resolve
done
echo "cloud-setup: ready"
