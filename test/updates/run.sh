#!/bin/bash
# Builds and runs the update check tests (no network).
#   test/updates/run.sh [--network]   --network also checks install.sh against the published v0.4.3 release, in a dry run
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/updates/main.swift Shared/Updates.swift Shared/Settings.swift -o "$out/updates"
xcrun clang -O -target arm64-apple-macos13.0 test/updates/proc.c -o "$out/proc"
[ "${1:-}" = --network ] && export SPACEBAR_TEST_NETWORK=1
SPACEBAR_TEST_PROC="$out/proc" SPACEBAR_SUPPORT_DIR="$out/support" "$out/updates"
