#!/bin/bash
# The preview extension's code under the hardened runtime, signed as build.sh signs it (test/hardened/main.swift): built from
# the extension's sources and PreviewViewController, signed with the built extension's own entitlements and the build's
# identity, and its writer under the runtime too. Quick Look cannot be asked to run this build without registering it, so the
# same code runs as an app; it shows Markdown, JSON, a zip, a PDF and an image off screen. Nothing registered or installed;
# macOS keeps a container under ~/Library/Containers/md.spacebar.test.hardened.
#   SKIP_BUILD=1   use build/spacebar.app as it is (otherwise ./build.sh --no-install, arm64 only)
set -euo pipefail
cd "$(dirname "$0")/../.."
[ "${SKIP_BUILD:-0}" = 1 ] || ARCHS=${ARCHS:-arm64} ./build.sh --no-install >/dev/null
built=build/spacebar.app/Contents/PlugIns/SpacebarPreview.appex
[ -d "$built" ] || { echo "FAIL no $built"; exit 1; }
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
PREVIEW_SRC=$(sed -nE '/^PREVIEW_SRC=\(/,/\)$/p' build.sh | sed -e 's/^PREVIEW_SRC=//' | tr -d '()')
WRITER_SRC=$(sed -nE 's/^compile "\$WRITER_BIN" -module-name "\$WRITER_EXE" //p' build.sh)
app=$out/Harness.app
id=md.spacebar.test.hardened
xpc=$app/Contents/XPCServices/$id.writer.xpc
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$xpc/Contents/MacOS" "$out/support" "$out/files"
printf '{"checkUpdates": false}' > "$out/support/settings.json"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -module-name SpacebarWriter $WRITER_SRC -o "$xpc/Contents/MacOS/SpacebarWriter"
# shellcheck disable=SC2086
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/hardened/main.swift Preview/PreviewViewController.swift $PREVIEW_SRC \
  -framework QuickLookUI -framework WebKit -framework PDFKit -framework AVKit -framework AVFoundation -framework QuickLookThumbnailing \
  -o "$app/Contents/MacOS/hardened"
plist() { printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string><key>CFBundleExecutable</key><string>%s</string><key>CFBundlePackageType</key><string>%s</string>%s</dict></plist>' "$@"; }
plist "$id" hardened APPL '<key>LSUIElement</key><true/>' > "$app/Contents/Info.plist"
plist "$id.writer" SpacebarWriter 'XPC!' "<key>XPCService</key><dict><key>ServiceType</key><string>Application</string><key>RunLoopType</key><string>NSRunLoop</string><key>EnvironmentVariables</key><dict><key>SPACEBAR_SUPPORT_DIR</key><string>$out/support</string></dict></dict>" \
  > "$xpc/Contents/Info.plist"
cp -R Preview/web "$app/Contents/Resources/web"
cp scripts/quicklook-types.txt "$app/Contents/Resources/"

codesign -d --entitlements - --xml "$built" > "$out/ent.plist" 2>/dev/null
plutil -convert json -o - "$out/ent.plist" | grep -qF '"com.apple.security.app-sandbox":true' || { echo "FAIL the built extension is not sandboxed"; exit 1; }
identity=$(codesign -dvv "$built" 2>&1 | sed -n 's/^Authority=//p' | head -1)
codesign --force --sign "${identity:--}" --options runtime --timestamp=none "$xpc" 2>/dev/null
codesign --force --sign "${identity:--}" --options runtime --timestamp=none --entitlements "$out/ent.plist" "$app" 2>/dev/null
[[ $(codesign -dv "$app" 2>&1) == *"(runtime)"* ]] || { echo "FAIL the harness is not signed with the runtime"; exit 1; }
echo "signed by ${identity:-ad-hoc} with $built's entitlements: $(plutil -convert json -o - "$out/ent.plist")"

f=$out/files
printf '# Hardened\n\nhardened marker 7f3a\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n' > "$f/note.md"
printf '{"hardenedKey": [1, 2, 3]}\n' > "$f/data.json"
mkdir "$out/zip" && echo hi > "$out/zip/inside-the-zip.txt" && (cd "$out/zip" && zip -q "$f/bundle.zip" inside-the-zip.txt)
python3 - "$f" <<'PY'
import struct, sys, zlib
d = sys.argv[1]
objs = [b'<< /Type /Catalog /Pages 2 0 R >>', b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R >>']
stream = b'0 0 1 rg 20 20 160 160 re f'
objs.append(b'<< /Length %d >>\nstream\n' % len(stream) + stream + b'\nendstream')
pdf, offs = b'%PDF-1.4\n', []
for i, o in enumerate(objs, 1):
    offs.append(len(pdf)); pdf += b'%d 0 obj\n' % i + o + b'\nendobj\n'
x = len(pdf)
pdf += b'xref\n0 %d\n0000000000 65535 f \n' % (len(objs) + 1) + b''.join(b'%010d 00000 n \n' % o for o in offs)
pdf += b'trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n' % (len(objs) + 1, x)
open(f'{d}/doc.pdf', 'wb').write(pdf)
chunk = lambda t, b: struct.pack('>I', len(b)) + t + b + struct.pack('>I', zlib.crc32(t + b) & 0xffffffff)
rows = b''.join(b'\x00' + b'\xff\x00\x00' * 64 for _ in range(64))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 64, 64, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
open(f'{d}/image.png', 'wb').write(png)
PY
SPACEBAR_SUPPORT_DIR="$out/support" "$app/Contents/MacOS/hardened" "$f"
