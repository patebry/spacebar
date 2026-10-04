#!/bin/bash
# Builds and runs the native player's checks (Preview/MediaPane.swift) in an off-screen window, and the info card's thumbnail
# (Preview/Thumbnail.swift). Nothing is heard: the one check that plays does so muted.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/mediapane/main.swift test/offscreen.swift Preview/MediaPane.swift Preview/PDFPane.swift Preview/Thumbnail.swift Preview/ImagePane.swift Preview/Gestures.swift \
  Shared/LinkPolicy.swift Shared/FolderListing.swift -o "$out/mediapane"
"$out/mediapane" "$out"
