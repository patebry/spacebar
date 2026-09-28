#!/bin/bash
# Builds and runs the Report a Problem checks, then checks the bundled uninstaller without running it: its syntax, and a
# --dry-run against a scratch HOME that lists only what it would remove (no network, nothing opened, nothing deleted).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/report/main.swift App/ProblemReport.swift -o "$out/report"
"$out/report"

fail=0
check() { local name=$1; shift; if "$@"; then echo "PASS $name"; else echo "FAIL $name"; fail=1; fi; }
home="$out/home"
app="$home/Applications/spacebar.app"
support="$home/Library/Application Support/spacebar"
mkdir -p "$app/Contents/PlugIns/SpacebarPreview.appex" "$support" "$home/Documents"
touch "$home/Documents/keep.md"
dry() { HOME="$home" sh scripts/uninstall.sh --dry-run "$@" </dev/null 2>&1; }
removed() { dry "$@" | sed -n 's/^would run: rm -rf //p'; }

check "uninstall.sh parses" sh -n scripts/uninstall.sh
check "uninstall --dry-run --purge removes only the app and the settings folder" \
  test "$(removed --purge)" = "$(printf '%s\n%s' "$app" "$support")"
check "without --purge the settings folder stays" test "$(removed)" = "$app"
check "uninstall unregisters the app's extensions" grep -qx "would run: pluginkit -r $app/Contents/PlugIns/SpacebarPreview.appex" <<<"$(dry)"
check "uninstall quits the extensions and their writers before it deletes anything" \
  test "$(dry | grep -n -e 'would quit the Quick Look extensions' -e 'would run: rm -rf' | head -1 | cut -d: -f2-)" = "would quit the Quick Look extensions running from $app, their writers first"
check "--no-register quits nothing" sh -c "! (HOME='$home' sh scripts/uninstall.sh --dry-run --no-register </dev/null 2>&1 | grep -q 'would quit')"
# Run from a private copy in a spacebar-update-* folder of TMPDIR, as the settings window starts it: the copy removes itself,
# and only with the marker. A dry run against the scratch HOME touches nothing else.
tmpd="$out/tmp"; mkdir -p "$tmpd/spacebar-update-self" "$tmpd/spacebar-update-kept"
cp scripts/uninstall.sh "$tmpd/spacebar-update-self/uninstall.sh"
cp scripts/uninstall.sh "$tmpd/spacebar-update-kept/uninstall.sh"
HOME="$home" TMPDIR="$tmpd/" SPACEBAR_UNINSTALL_SELF=1 sh "$tmpd/spacebar-update-self/uninstall.sh" --dry-run </dev/null >/dev/null 2>&1
HOME="$home" TMPDIR="$tmpd/" sh "$tmpd/spacebar-update-kept/uninstall.sh" --dry-run </dev/null >/dev/null 2>&1
check "started from the settings window, it removes its own private copy" test ! -e "$tmpd/spacebar-update-self"
check "without the marker its folder stays" test -e "$tmpd/spacebar-update-kept/uninstall.sh"
check "a dry run changes nothing" test -d "$app" -a -d "$support" -a -f "$home/Documents/keep.md"
exit $fail
