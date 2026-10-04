#!/bin/bash
# Builds and runs the checks of a disk image's info card details (Preview/DiskImage.swift) on images hdiutil makes here without
# a file system (so nothing is attached or mounted), converted to each format, one encrypted, and hand-made hostile trailers.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
hdiutil create -size 1m -layout NONE -quiet "$out/raw.dmg"
for f in UDZO ULFO UDBZ UDRO; do hdiutil convert "$out/raw.dmg" -format $f -quiet -o "$out/$f.dmg"; done
printf 'spacebar' | hdiutil create -size 1m -layout NONE -encryption AES-256 -stdinpass -quiet "$out/locked.dmg"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/diskimage/main.swift Preview/DiskImage.swift Shared/FolderListing.swift \
  -o "$out/diskimage"
"$out/diskimage" "$out"
