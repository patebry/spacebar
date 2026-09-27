#!/bin/bash
# Builds and runs the filter key checks (no window, no events).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/filterkeys/main.swift Shared/WriterProtocol.swift -o "$out/filterkeys"
"$out/filterkeys"
