#!/bin/bash
# Large files through the Space helper's viewer, off screen (test/bigfiles/main.swift): 16 MB CSVs (ASCII, CJK, Windows-1252)
# and a 50,000-row one, 2 MB of minified JSON, a 2 MB source file, 4 MB of Markdown, a 500-page PDF, a 12,000 x 12,000 PNG, a
# zip of 10,000 entries and a folder of 5,000 files. For each: show -> DOM drawn, -> animation frame, -> content up; the
# viewer's longest main-thread stall; its peak footprint. Then two large files shown back to back, and while the page is busy:
# the second is the one drawn. No key or mouse events, no window on screen, nothing written outside a temporary folder.
#   PERF_TARGETS=0 (CI): the stall and memory targets are printed, not graded; every other check still is
#   RUNS=3 (shows per file)   ONLY=CSV (only the files whose name contains this; ONLY=pairs, only the back-to-back shows)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
PREVIEW_SRC=$(sed -nE '/^PREVIEW_SRC=\(/,/\)$/p' build.sh | sed -e 's/^PREVIEW_SRC=//' | tr -d '()')
app=$out/Harness.app
id=md.spacebar.test.bigfiles
xpc=$app/Contents/XPCServices/$id.writer.xpc
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$xpc/Contents/MacOS" "$out/support" "$out/files"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/bigfiles/main.swift test/offscreen.swift Viewer/Viewer.swift Viewer/PanelFrame.swift Viewer/FinderCopy.swift Shared/HelperProtocol.swift $PREVIEW_SRC \
  -framework QuickLookUI -framework WebKit -framework PDFKit -framework AVKit -framework AVFoundation -framework QuickLookThumbnailing \
  -o "$app/Contents/MacOS/bigfiles"
# The scenario harness's stub writer: it lists archives as the real writer does.
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/scenarios/writer/main.swift Writer/EditTextView.swift Shared/WriterProtocol.swift Shared/ArchiveListing.swift \
  Shared/FolderListing.swift Shared/Settings.swift Shared/LinkPolicy.swift \
  -o "$xpc/Contents/MacOS/stubwriter"
plist() { printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string><key>CFBundlePackageType</key><string>%s</string>%s</dict></plist>' "$@"; }
plist "$id" bigfiles APPL '<key>LSUIElement</key><true/>' > "$app/Contents/Info.plist"
plist "$id.writer" stubwriter 'XPC!' '<key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>RunLoopType</key><string>NSRunLoop</string></dict>' \
  > "$xpc/Contents/Info.plist"
cp -R Preview/web "$app/Contents/Resources/web"
cp scripts/quicklook-types.txt "$app/Contents/Resources/"
codesign --force --sign - "$xpc" 2>/dev/null
codesign --force --sign - "$app" 2>/dev/null
python3 test/bigfiles/make.py "$out/files"
"$app/Contents/MacOS/bigfiles" "$out/files" --fixtures
SPACEBAR_SUPPORT_DIR="$out/support" "$app/Contents/MacOS/bigfiles" "$out/files"
