#!/bin/bash
# Builds and runs the text encoding checks (TextDecoding in Shared/FolderListing.swift) on the fixtures beside this script:
# Windows-1252, Latin-1, UTF-16 and UTF-32 with and without byte order marks, Shift JIS, and binary that must stay binary.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/encoding/main.swift Shared/FolderListing.swift -o "$out/encoding"
"$out/encoding" test/encoding/fixtures
