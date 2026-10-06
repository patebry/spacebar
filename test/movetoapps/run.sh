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
SPACEBAR_SUPPORT_DIR="$out/support" "$out/movetoapps" "$out/ro" "$out/rw" "$out/scratch"
