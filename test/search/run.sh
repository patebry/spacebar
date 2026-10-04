#!/bin/bash
# Builds and runs the contents search checks (ContentSearch in Shared/FolderScan.swift): matching, snippets, what is searched
# and skipped, the caps, cancellation, and the time to the first result on a generated 1,000-file repository and on this
# repository itself (read only).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/search/main.swift Shared/FolderScan.swift Shared/FolderListing.swift -o "$out/search"
"$out/search" "$out/fx" "$PWD"
