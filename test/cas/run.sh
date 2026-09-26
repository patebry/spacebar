#!/bin/bash
# Builds and runs the compare-and-swap write checks.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/cas/main.swift Writer/FileWrite.swift -o "$out/cas"
"$out/cas"
