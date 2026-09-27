#!/bin/bash
# Builds and runs the spacebar: scheme resolution checks against a temporary support folder.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/scheme/main.swift Shared/Settings.swift Shared/WebShell.swift Shared/FolderListing.swift Shared/FolderScan.swift -framework WebKit -o "$out/scheme"
SPACEBAR_SUPPORT_DIR="$out/support" "$out/scheme" "$PWD/Preview/web"
