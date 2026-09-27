#!/bin/bash
# Builds and runs the native PDF view's checks (Preview/PDFPane.swift) in an off-screen window: layout, messages, teardown.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/pdfpane/main.swift Preview/PDFPane.swift Shared/LinkPolicy.swift Shared/FolderListing.swift -o "$out/pdfpane"
"$out/pdfpane" "$out"
