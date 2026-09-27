#!/bin/bash
# Builds and runs the HTML view's checks (Preview/HTMLPane.swift) in an off-screen window: which files run scripts and load from
# the web (a file made on this Mac) and which do neither (a downloaded one, by its quarantine flag). The only server is on 127.0.0.1.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/htmlpane/main.swift Preview/HTMLPane.swift Preview/PDFPane.swift \
  Shared/LinkPolicy.swift Shared/FolderListing.swift -o "$out/htmlpane"
"$out/htmlpane" "$out"
