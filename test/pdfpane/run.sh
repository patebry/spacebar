#!/bin/bash
# Builds and runs the native PDF view's checks (Preview/PDFPane.swift) in an off-screen window: layout, messages, teardown.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/pdfpane/main.swift test/offscreen.swift Preview/PDFPane.swift Shared/LinkPolicy.swift Shared/FolderListing.swift -o "$out/pdfpane"
perl -e 'alarm 120; exec @ARGV' "$out/pdfpane" "$out"
# Again as a GitHub runner draws: a 1x display, scroll bars always shown.
mkdir "$out/1x"
perl -e 'alarm 120; exec @ARGV' "$out/pdfpane" "$out/1x" -backingScale 1 -AppleShowScrollBars Always
