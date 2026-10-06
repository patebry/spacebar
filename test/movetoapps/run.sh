#!/bin/bash
# Builds and runs the checks of the launch-time offer to move a copy into Applications: the decision against scratch folders,
# and the volume facts of a small disk image attached hidden (-nobrowse), read-only and writable. No window, no input.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
mounts=()
cleanup() {
  for m in ${mounts[@]+"${mounts[@]}"}; do hdiutil detach -quiet -force "$m" 2>/dev/null || true; done
  rm -rf "$out"
}
trap cleanup EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/movetoapps/main.swift App/InstallLocation.swift \
  App/MoveToApplications.swift Shared/Updates.swift Shared/Settings.swift -o "$out/movetoapps"
hdiutil create -quiet -size 2m -fs HFS+ -volname sbtest "$out/rw.dmg"
hdiutil convert -quiet "$out/rw.dmg" -format UDZO -o "$out/ro.dmg"
for kind in ro rw; do
  mkdir "$out/$kind"
  flags=(-nobrowse -noautoopen -mountpoint "$out/$kind")
  [ "$kind" = ro ] && flags+=(-readonly)
  hdiutil attach -quiet "${flags[@]}" "$out/$kind.dmg"
  mounts+=("$out/$kind")
done
# A bundle with an app nested in it, signed ad hoc inside out, and a copy whose nested app was changed after signing.
bundle() {
  mkdir -p "$1/Contents/MacOS"
  cp "$out/movetoapps" "$1/Contents/MacOS/$2"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleExecutable</key><string>%s</string><key>CFBundleIdentifier</key><string>test.spacebar.%s</string><key>CFBundleShortVersionString</key><string>9.9</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>\n' "$2" "$2" > "$1/Contents/Info.plist"
}
bundle "$out/Nested.app" Nested
bundle "$out/Nested.app/Contents/Helpers/Inner.app" Inner
codesign --force --sign - "$out/Nested.app/Contents/Helpers/Inner.app" 2>/dev/null
codesign --force --sign - "$out/Nested.app" 2>/dev/null
ditto "$out/Nested.app" "$out/Tampered.app"
printf 'x' >> "$out/Tampered.app/Contents/Helpers/Inner.app/Contents/MacOS/Inner"
SPACEBAR_SUPPORT_DIR="$out/support" "$out/movetoapps" "$out/ro" "$out/rw" "$out/scratch" "$out/Nested.app" "$out/Tampered.app"
