#!/bin/bash
# Builds and runs the checks of Apple's previews in the panel (Preview/QLFallbackPane.swift, FileTypes.appleQuickLookTypes) in an
# off-screen window: the allowlist against scripts/quicklook-types.txt, which files get the view, placing, the generic-icon
# fallback and teardown. Then a copy signed with the extension's sandbox entitlements shows a Word document rendering (macOS keeps
# a container under ~/Library/Containers/md.spacebar.test.qlpane). That copy is an app, not an extension: it renders without the
# mach-lookup exception too, so whether the extension needs it is seen only through Quick Look (FINDINGS.md).
# Opens no Quick Look window.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
MACH='<key>com.apple.security.temporary-exception.mach-lookup.global-name</key><array><string>com.apple.quicklook</string><string>com.apple.quicklook.ThumbnailsAgent</string></array>'
grep -qF "$MACH" build.sh || { echo "FAIL build.sh no longer grants the mach-lookup exception this test signs with"; exit 1; }
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>md.spacebar.test.qlpane</string></dict></plist>' > "$out/Info.plist"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/qlpane/main.swift Preview/QLFallbackPane.swift Preview/PDFPane.swift \
  Shared/LinkPolicy.swift Shared/FolderListing.swift -framework Quartz \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/Info.plist" -o "$out/qlpane"
"$out/qlpane" "$out"
# As build.sh signs the extensions (READ_ACCESS=abs-ro).
cp "$out/qlpane" "$out/qlpane-sandboxed"
{ echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
  echo '<key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.files.user-selected.read-only</key><true/>'
  echo '<key>com.apple.security.network.client</key><true/>'
  echo '<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key><array><string>/</string></array>'
  echo "$MACH"
  echo '</dict></plist>'; } > "$out/ent.plist"
codesign --force --sign - -i md.spacebar.test.qlpane --entitlements "$out/ent.plist" "$out/qlpane-sandboxed" 2>/dev/null
QLPANE_SANDBOX=1 "$out/qlpane-sandboxed" "$out"
