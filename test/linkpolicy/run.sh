#!/bin/bash
# Builds and runs the link policy checks.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/linkpolicy/main.swift Shared/LinkPolicy.swift -o "$out/linkpolicy"
"$out/linkpolicy"
