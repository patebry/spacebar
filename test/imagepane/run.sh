#!/bin/bash
# Builds and runs the checks of the native image view (Preview/ImagePane.swift) and its routing (FileTypes, FileView) in an
# off-screen window, with fixtures made here by ImageIO (HEIC, TIFF, PSD, EXR, TGA, JPEG 2000, ICNS; AVIF when ffmpeg is on the
# PATH). Then a copy signed with the extension's sandbox entitlements decodes them, as the viewer and the extension do.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>md.spacebar.test.imagepane</string></dict></plist>' > "$out/Info.plist"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/imagepane/main.swift Preview/ImagePane.swift Preview/PDFPane.swift \
  Shared/LinkPolicy.swift Shared/FolderListing.swift -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/Info.plist" -o "$out/imagepane"
"$out/imagepane" "$out"
cp "$out/imagepane" "$out/imagepane-sandboxed"
{ echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
  echo '<key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.files.user-selected.read-only</key><true/>'
  echo '<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key><array><string>/</string></array>'
  echo '</dict></plist>'; } > "$out/ent.plist"
codesign --force --sign - -i md.spacebar.test.imagepane --options runtime --entitlements "$out/ent.plist" "$out/imagepane-sandboxed" 2>/dev/null
IMAGEPANE_SANDBOX=1 "$out/imagepane-sandboxed" "$out"
