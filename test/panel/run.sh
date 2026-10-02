#!/bin/bash
# Builds and runs the Space panel's own checks: the frame it remembers per display (Viewer/PanelFrame.swift), in memory
# defaults, and what ⌘C puts on the pasteboard (Viewer/FinderCopy.swift), on a private named pasteboard, never the
# clipboard. Then the panel as a real window, parked off screen (test/panel/window/main.swift): the frame it is given holds,
# and a pinch the helper hands over zooms an image and a PDF.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/panel/main.swift Viewer/PanelFrame.swift Viewer/FinderCopy.swift -o "$out/panel"
"$out/panel"

PREVIEW_SRC=$(sed -nE '/^PREVIEW_SRC=\(/,/\)$/p' build.sh | sed -e 's/^PREVIEW_SRC=//' | tr -d '()')
app=$out/PanelWindow.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$out/support" "$out/files"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/panel/window/main.swift test/offscreen.swift Helper/Decision.swift Viewer/Viewer.swift Viewer/PanelFrame.swift Viewer/FinderCopy.swift Shared/HelperProtocol.swift $PREVIEW_SRC \
  -framework QuickLookUI -framework WebKit -framework PDFKit -framework AVKit -framework AVFoundation -framework QuickLookThumbnailing \
  -o "$app/Contents/MacOS/panelwindow"
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>md.spacebar.test.panelwindow</string><key>CFBundleExecutable</key><string>panelwindow</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>' > "$app/Contents/Info.plist"
cp -R Preview/web "$app/Contents/Resources/web"
cp scripts/quicklook-types.txt "$app/Contents/Resources/"
codesign --force --sign - "$app" 2>/dev/null
SPACEBAR_SUPPORT_DIR="$out/support" "$app/Contents/MacOS/panelwindow" "$out/files"
