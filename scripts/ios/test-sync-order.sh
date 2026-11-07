#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
run_dir="$(mktemp -d "${TMPDIR:-/tmp}/nanomuse-sync-order.XXXXXX")"
trap 'rm -rf "$run_dir"' EXIT
swiftc -warnings-as-errors \
  "$root/android/src/ios/NanoMuse/NanoMuseSyncOrdering.swift" \
  "$root/scripts/ios/sync-order-tests/main.swift" \
  -lsqlite3 -o "$run_dir/sync-order-test"
"$run_dir/sync-order-test" "$run_dir/messages.sqlite"
