#!/bin/bash
# fakefsify stores architecture-independent file metadata and copies the guest
# binaries unchanged. Only this packaging tool must match the Mac host.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ISH_DIR="$REPO_DIR/android/deps/ish"

if [[ "$(uname -m)" == "x86_64" ]]; then
    meson setup "$ISH_DIR/build-native" "$ISH_DIR" \
        --buildtype=release -Dlog="" -Dkernel=ish -Dengine=asbestos -Dguest_arch=x86
    ninja -C "$ISH_DIR/build-native" tools/fakefsify
fi

exec bash "$REPO_DIR/android/deps/prepare_alpine_rootfs.sh"
