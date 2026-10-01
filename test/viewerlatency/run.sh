#!/bin/bash
# Times the Space helper's viewer off screen: its real Viewer and PreviewController, driven through the call the helper makes
# over XPC (show, then key and close), with the panel parked off every display. For each kind of file: show -> the panel's
# first visible frame in the window server, and show -> content painted (the page's render, an <img> decoded, a native view up).
# Then an arrow key -> the next file painted, and the process's memory at idle. Then what a suspended panel shows when it is
# restored, closed or replaced (first visible frames), and that a fallback view is rendered once. No key events, no window on
# screen.
#   RUNS=20 (samples per file kind)
#   LATENCY_TARGETS=0 (CI): the timing and memory targets are printed, not graded; every other check still is
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
PREVIEW_SRC=$(sed -nE '/^PREVIEW_SRC=\(/,/\)$/p' build.sh | sed -e 's/^PREVIEW_SRC=//' | tr -d '()')
app=$out/Harness.app
id=md.spacebar.test.viewerlatency
xpc=$app/Contents/XPCServices/$id.writer.xpc
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$xpc/Contents/MacOS" "$out/support" "$out/files"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/viewerlatency/main.swift test/offscreen.swift test/nsevents.swift Viewer/Viewer.swift Viewer/PanelFrame.swift Viewer/FinderCopy.swift Shared/HelperProtocol.swift $PREVIEW_SRC \
  -framework QuickLookUI -framework WebKit -framework PDFKit -framework AVKit -framework AVFoundation -framework QuickLookThumbnailing \
  -o "$app/Contents/MacOS/viewerlatency"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/viewerlatency/writer/main.swift Shared/WriterProtocol.swift -o "$xpc/Contents/MacOS/stubwriter"
plist() { printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string><key>CFBundlePackageType</key><string>%s</string>%s</dict></plist>' "$@"; }
plist "$id" viewerlatency APPL '<key>LSUIElement</key><true/>' > "$app/Contents/Info.plist"
plist "$id.writer" stubwriter 'XPC!' '<key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>RunLoopType</key><string>NSRunLoop</string></dict>' \
  > "$xpc/Contents/Info.plist"
cp -R Preview/web "$app/Contents/Resources/web"
cp scripts/quicklook-types.txt "$app/Contents/Resources/"
codesign --force --sign - "$xpc" 2>/dev/null
codesign --force --sign - "$app" 2>/dev/null
cp README.md "$out/files/notes.md"
cp Preview/PreviewController.swift "$out/files/Controller.swift"
"$app/Contents/MacOS/viewerlatency" "$out/files" 0 --fixtures
SPACEBAR_SUPPORT_DIR="$out/support" "$app/Contents/MacOS/viewerlatency" "$out/files" "${RUNS:-20}"
