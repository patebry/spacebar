#!/bin/bash
# Builds and runs the checks of the folder grid's thumbnail pipeline (Preview/Thumbnail.swift) and the scheme handler's `thumb`
# host (Shared/WebShell.swift): its caps (concurrency, cache bytes and count), cancellation of loads dropped while queued or
# being made, and that the host serves only what its source allows, with fixtures made here by ImageIO.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/thumbs/main.swift Preview/Thumbnail.swift Preview/ImagePane.swift Preview/Gestures.swift \
  Preview/PDFPane.swift Shared/LinkPolicy.swift Shared/FolderListing.swift Shared/WebShell.swift Shared/Settings.swift -framework WebKit -o "$out/thumbs"
"$out/thumbs" "$out"
