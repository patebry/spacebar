#!/bin/bash
# Day-in-the-life scenarios through the Space helper's viewer, off screen (test/scenarios/viewer/main.swift): a repo folder
# walked with ↓, a 50,000-row CSV sorted and scrolled, broken and 2 MB JSON, every file of a messy real-world corpus, video and
# audio formats, a multi-file selection, hostile files, missing images, and a space typed into an edit. The corpus is made at
# test time (corpus_real.py) and the media with ffmpeg (make_media.sh); without ffmpeg the media flow is skipped. No key or
# mouse event reaches the system (the edit's keys are NSEvents inside the stub writer), no window on screen, nothing written
# outside a temporary folder.
#   FLOWS=1,4 ...       only these flows (1-8, 10)
#   SCEN_TIMING=0       latency targets printed, not graded (CI, a shared runner)
#   SCEN_STRICT=1       a KNOWN line (a reported bug, not yet fixed) fails the run
#   VIDEO_TESTS=<dir>   walk this folder of clips instead of making them (e.g. ~/Desktop/spacebar-film/video-tests)
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
cleanup() { chmod -R u+rwX "$out" 2>/dev/null || true; rm -rf "$out"; }
trap cleanup EXIT
PREVIEW_SRC=$(sed -nE '/^PREVIEW_SRC=\(/,/\)$/p' build.sh | sed -e 's/^PREVIEW_SRC=//' | tr -d '()')
app=$out/Harness.app
id=md.spacebar.test.scenarios
xpc=$app/Contents/XPCServices/$id.writer.xpc
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$xpc/Contents/MacOS" "$out/support"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/scenarios/viewer/main.swift test/offscreen.swift Helper/Decision.swift Viewer/Viewer.swift Viewer/PanelFrame.swift Viewer/FinderCopy.swift Shared/HelperProtocol.swift $PREVIEW_SRC \
  -framework QuickLookUI -framework WebKit -framework PDFKit -framework AVKit -framework AVFoundation -framework QuickLookThumbnailing \
  -o "$app/Contents/MacOS/scenarios"
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/scenarios/writer/main.swift Writer/EditTextView.swift Shared/WriterProtocol.swift Shared/ArchiveListing.swift \
  Shared/FolderListing.swift Shared/Settings.swift Shared/LinkPolicy.swift \
  -o "$xpc/Contents/MacOS/stubwriter"
plist() { printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string><key>CFBundlePackageType</key><string>%s</string>%s</dict></plist>' "$@"; }
plist "$id" scenarios APPL '<key>LSUIElement</key><true/>' > "$app/Contents/Info.plist"
plist "$id.writer" stubwriter 'XPC!' '<key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>RunLoopType</key><string>NSRunLoop</string></dict>' \
  > "$xpc/Contents/Info.plist"
cp -R Preview/web "$app/Contents/Resources/web"
cp scripts/quicklook-types.txt "$app/Contents/Resources/"
codesign --force --sign - "$xpc" 2>/dev/null
codesign --force --sign - "$app" 2>/dev/null

python3 test/scenarios/corpus_real.py "$out/data"
videos=${VIDEO_TESTS:-}
if [ -z "$videos" ]; then
  if test/scenarios/make_media.sh "$out/media" > /dev/null; then videos=$out/media; else echo "could not make the media clips (no ffmpeg?): the media flow is skipped"; fi
fi
SPACEBAR_SUPPORT_DIR="$out/support" "$app/Contents/MacOS/scenarios" "$out/data" "$videos"
