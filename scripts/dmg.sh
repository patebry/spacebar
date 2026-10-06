#!/bin/bash
# Makes build/spacebar.dmg from build/spacebar.app (./build.sh --no-install first): a compressed image holding the app and a
# link to /Applications, laid out for dragging one onto the other (scripts/dmg/settings.py), signed with the identity that
# signed the app. Not notarized: the release workflow notarizes and staples it. Changes nothing outside build/.
# The layout is written by dmgbuild, without Finder:
#   python3 -m pip install --require-hashes --only-binary :all: --no-deps -r scripts/dmg/requirements.txt
#   DMGBUILD=...       the dmgbuild command (default: dmgbuild on PATH)
#   SIGN_ID=...        identity to sign the image with (default the app's signer; an ad-hoc app leaves the image unsigned)
#   SIGN_KEYCHAIN=...  TIMESTAMP=1|0   as build.sh (TIMESTAMP default: 1 for a Developer ID identity)
set -euo pipefail
cd "$(dirname "$0")/.."
APP=build/spacebar.app
DMG=build/spacebar.dmg
[ -d "$APP" ] || { echo "no $APP: run ./build.sh --no-install first" >&2; exit 1; }
DMGBUILD=${DMGBUILD:-dmgbuild}
command -v "$DMGBUILD" > /dev/null || {
  echo "no dmgbuild: install it, in a venv if your python3 is externally managed, with" >&2
  echo "  python3 -m pip install --require-hashes --only-binary :all: --no-deps -r scripts/dmg/requirements.txt" >&2
  exit 1
}
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

rm -f "$DMG"
# hdiutil sometimes fails with "Resource busy" on a CI runner; a second try a few seconds later succeeds.
for try in 1 2 3; do
  "$DMGBUILD" -s scripts/dmg/settings.py -D app="$APP" -D icon=App/AppIcon.icns -D background=scripts/dmg/background.tiff \
    spacebar "$DMG" > /dev/null && break
  [ "$try" = 3 ] && { echo "dmgbuild failed 3 times" >&2; exit 1; }
  rm -f "$DMG"
  sleep 5
done
if [ -n "$SIGN_ID" ] && [ "$SIGN_ID" != - ]; then
  codesign --force --sign "$SIGN_ID" ${SIGN_KEYCHAIN:+--keychain "$SIGN_KEYCHAIN"} "$TIMESTAMP_ARG" "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"
else
  echo "note: $APP is ad-hoc signed, so $DMG is not signed"
fi
hdiutil verify -quiet "$DMG"
echo "built $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '), SIGN_ID=${SIGN_ID:--} TIMESTAMP=$TIMESTAMP)"
