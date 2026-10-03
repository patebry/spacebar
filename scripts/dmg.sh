#!/bin/bash
# Makes build/spacebar.dmg from build/spacebar.app (./build.sh --no-install first): a compressed image holding the app and a
# link to /Applications, signed with the identity that signed the app. Not notarized: the release workflow notarizes and
# staples it. Changes nothing outside build/.
#   SIGN_ID=...        identity to sign the image with (default the app's signer; an ad-hoc app leaves the image unsigned)
#   SIGN_KEYCHAIN=...  TIMESTAMP=1|0   as build.sh (TIMESTAMP default: 1 for a Developer ID identity)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/spacebar.app
DMG=build/spacebar.dmg
[ -d "$APP" ] || { echo "no $APP: run ./build.sh --no-install first" >&2; exit 1; }
codesign --verify --deep --strict "$APP"
SIGN_ID=${SIGN_ID:-$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)}
if [ -z "${TIMESTAMP:-}" ]; then
  TIMESTAMP=0
  if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != - ]; then
    identity=$(security find-identity -p codesigning ${SIGN_KEYCHAIN:+"$SIGN_KEYCHAIN"} 2>/dev/null | grep -F -- "$SIGN_ID" || true)
    [[ $identity == *'"Developer ID Application: '* || $SIGN_ID == "Developer ID Application: "* ]] && TIMESTAMP=1
  fi
fi
case $TIMESTAMP in 1) TIMESTAMP_ARG=--timestamp ;; 0) TIMESTAMP_ARG=--timestamp=none ;; *) echo "TIMESTAMP must be 1 or 0" >&2; exit 2 ;; esac

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$APP" "$stage/spacebar.app"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname spacebar -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != - ]; then
  codesign --force --sign "$SIGN_ID" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$TIMESTAMP_ARG" "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"
else
  echo "note: $APP is ad-hoc signed, so $DMG is not signed"
fi
hdiutil verify -quiet "$DMG"
echo "built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), SIGN_ID=${SIGN_ID:--} TIMESTAMP=$TIMESTAMP)"
