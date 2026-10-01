#!/bin/bash
# Builds and runs the native rich text view's checks (Preview/RichTextPane.swift) in an off-screen window: RTF and RTFD read by
# AppKit's RTF reader only, the file view and kind that route them there, layout, dark mapping, links and teardown.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/richtext/main.swift test/offscreen.swift Preview/RichTextPane.swift Preview/PDFPane.swift \
  Shared/LinkPolicy.swift Shared/FolderListing.swift -o "$out/richtext"
"$out/richtext" "$out"
