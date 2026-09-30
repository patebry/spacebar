#!/bin/bash
# Realistic editing sessions end to end (test/editflows/main.swift): the real page, PreviewController and writer, the writer's
# keys typed in-process by test/editflows/driver.swift, each saved file checked byte for byte, in both hosts (the Space panel's
# viewer and Quick Look's controller), and for the panel the helper's routing of each key with the text session the viewer reports. Off screen: the edit panel is never
# ordered in and never takes the keyboard; no event reaches the system, nothing is written outside a temp folder.
#   HOSTS="panel quicklook"   the hosts to run
#   CASES=md:,plain:          only cases whose names contain one of these
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
PREVIEW_SRC=$(sed -nE '/^PREVIEW_SRC=\(/,/\)$/p' build.sh | sed -e 's/^PREVIEW_SRC=//' | tr -d '()')
WRITER_SRC=$(sed -nE 's/^compile "\$WRITER_BIN" -module-name "\$WRITER_EXE" //p' build.sh)
app=$out/Harness.app
id=md.spacebar.test.editflows
xpc=$app/Contents/XPCServices/$id.writer.xpc
token=$(uuidgen)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$xpc/Contents/MacOS" "$out/support" "$out/work" "$out/writer"
printf '{"checkUpdates": false}' > "$out/support/settings.json"
# The real writer, with the driver in front of its main.swift.
{ cat test/editflows/driver.swift; cat Writer/main.swift; } > "$out/writer/main.swift"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -module-name SpacebarWriter "$out/writer/main.swift" ${WRITER_SRC/Writer\/main.swift/} \
  -o "$xpc/Contents/MacOS/SpacebarWriter"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/editflows/main.swift Helper/Decision.swift Viewer/Viewer.swift Viewer/PanelFrame.swift Viewer/FinderCopy.swift Shared/HelperProtocol.swift $PREVIEW_SRC \
  -framework QuickLookUI -framework WebKit -framework PDFKit -framework AVKit -framework AVFoundation -framework QuickLookThumbnailing \
  -o "$app/Contents/MacOS/editflows"
plist() { printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string><key>CFBundlePackageType</key><string>%s</string>%s</dict></plist>' "$@"; }
plist "$id" editflows APPL '<key>LSUIElement</key><true/>' > "$app/Contents/Info.plist"
plist "$id.writer" SpacebarWriter 'XPC!' "<key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>RunLoopType</key><string>NSRunLoop</string><key>EnvironmentVariables</key><dict><key>SPACEBAR_SUPPORT_DIR</key><string>$out/support</string><key>EDITFLOWS_DIR</key><string>$out/work</string><key>EDITFLOWS_TOKEN</key><string>$token</string></dict></dict>" \
  > "$xpc/Contents/Info.plist"
cp -R Preview/web "$app/Contents/Resources/web"
cp scripts/quicklook-types.txt "$app/Contents/Resources/"
codesign --force --sign - "$xpc" 2>/dev/null
codesign --force --sign - "$app" 2>/dev/null
status=0
for h in ${HOSTS:-panel quicklook}; do
  rm -f "$out/work/result.json"
  EDITFLOWS_TOKEN=$token SPACEBAR_SUPPORT_DIR="$out/support" "$app/Contents/MacOS/editflows" "$h" "$out/work" || status=1
done
exit $status
