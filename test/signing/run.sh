#!/bin/bash
# Lists every Mach-O in a built spacebar.app with its signature's flags, authority, timestamp and entitlements, and fails unless
# each one is signed under the hardened runtime, the bundle verifies, and none carries get-task-allow or an entitlement that
# lets a library in. Reads the build only: nothing is signed, installed or registered.
#   test/signing/run.sh [app]      default build/spacebar.app (./build.sh --no-install first)
#   NOTARY=1   also require what notarization does: a secure timestamp and a Developer ID Application authority on each
set -euo pipefail
cd "$(dirname "$0")/../.."
app=${1:-build/spacebar.app}
[ -d "$app" ] || { echo "FAIL no $app: run ./build.sh --no-install first"; exit 1; }
failures=0
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
count=0
while IFS= read -r -d '' f; do
  file -b "$f" | grep -q 'Mach-O' || continue
  count=$((count + 1))
  info=$(codesign -dvv "$f" 2>&1) || { fail "$f is not signed"; continue; }
  flags=$(sed -nE 's/^CodeDirectory .*flags=(0x[0-9a-f]+\([^)]*\)).*/\1/p' <<<"$info")
  authority=$(sed -n 's/^Authority=//p' <<<"$info" | head -1)
  stamp=$(sed -n 's/^Timestamp=//p' <<<"$info")
  xml=$(codesign -d --entitlements - --xml "$f" 2>/dev/null || true)
  ents={}
  [ -n "$xml" ] && ents=$(plutil -convert json -o - - <<<"$xml")
  echo "${f#"$app"/}"
  echo "  identifier=$(sed -n 's/^Identifier=//p' <<<"$info") flags=$flags"
  echo "  authority=${authority:-ad-hoc} timestamp=${stamp:-none}"
  echo "  entitlements=$ents"
  [[ $flags == *runtime* ]] || fail "$f is not signed with the hardened runtime"
  for k in com.apple.security.get-task-allow com.apple.security.cs.allow-dyld-environment-variables com.apple.security.cs.disable-library-validation; do
    [[ $ents == *"\"$k\""* ]] && fail "$f carries $k"
  done
  if [ "${NOTARY:-0}" = 1 ]; then
    [ -n "$stamp" ] || fail "$f has no secure timestamp"
    [[ $authority == "Developer ID Application: "* ]] || fail "$f is not signed with a Developer ID Application identity (${authority:-ad-hoc})"
  fi
done < <(find "$app" -type f -print0)
# The app, two extensions and their writers, the Space helper, its viewer and the viewer's writer.
[ "$count" -ge 8 ] || fail "expected at least 8 Mach-O files, found $count"
codesign --verify --deep --strict --verbose=2 "$app" || fail "$app does not verify"
if [ "$failures" != 0 ]; then echo "signing: $failures failed"; exit 1; fi
echo "signing: $count Mach-O files, all passed"
