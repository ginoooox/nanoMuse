#!/bin/bash
# Build the host-side packaging tool for an Intel Mac when necessary.
# The Alpine guest binaries remain aarch64, as in the upstream build.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ISH_DIR="$REPO_DIR/android/deps/ish"

if [[ "$(uname -m)" == "x86_64" ]]; then
    meson setup "$ISH_DIR/build-native" "$ISH_DIR" \
        --buildtype=release -Dlog="" -Dkernel=ish -Dengine=asbestos -Dguest_arch=x86
    ninja -C "$ISH_DIR/build-native" tools/fakefsify
fi

exec bash "$REPO_DIR/android/deps/prepare_alpine_rootfs.sh"
