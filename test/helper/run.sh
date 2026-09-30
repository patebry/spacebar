#!/bin/bash
# Builds and runs the Space helper's routing checks (no window, no events, no Accessibility).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/helper/main.swift Helper/Decision.swift Helper/Link.swift Shared/HelperProtocol.swift -o "$out/helper"
"$out/helper" test/helper/contexts.json
