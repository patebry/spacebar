#!/bin/bash
# Builds and runs the compare-and-swap write checks, the writer's allow-list and refusals, and the encoding round trips.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/cas/main.swift Writer/FileWrite.swift Shared/FolderListing.swift -o "$out/cas"
"$out/cas"
