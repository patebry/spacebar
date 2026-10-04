#!/bin/bash
# Builds and runs the welcome sheet's sample folder checks against a temporary support folder (never the real one).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/welcome/main.swift App/SampleFolder.swift Shared/Settings.swift Shared/QuickLookClaims.swift -o "$out/welcome"
SPACEBAR_SUPPORT_DIR="$out/support" "$out/welcome"
