#!/bin/bash
# Builds and runs the update check tests (no network).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/updates/main.swift Shared/Updates.swift Shared/Settings.swift -o "$out/updates"
xcrun clang -O -target arm64-apple-macos13.0 test/updates/proc.c -o "$out/proc"
SPACEBAR_TEST_PROC="$out/proc" SPACEBAR_SUPPORT_DIR="$out/support" "$out/updates"
