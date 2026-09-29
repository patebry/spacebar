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
helper_steps() { dry "$@" | grep -n -e 'launchctl' -e "Space helper's viewer" -e 'tccutil' -e 'Quick Look extensions' -e 'rm -rf' | cut -d: -f2-; }
expected_helper="would run: launchctl bootout gui/$(id -u)/md.spacebar.helper
would quit the Space helper's viewer running from $app, its writer first
would run: tccutil reset Accessibility md.spacebar.helper
would run: tccutil reset All md.spacebar.viewer
would quit the Quick Look extensions running from $app, their writers first"
check "uninstall boots the helper out, quits its viewer, then resets its permissions, all before the extensions" \
  test "$(helper_steps | head -5)" = "$expected_helper"
check "--no-register leaves launchd and TCC alone" sh -c "! (HOME='$home' sh scripts/uninstall.sh --dry-run --no-register </dev/null 2>&1 | grep -qe launchctl -e tccutil)"
check "the uninstaller never resets Background Task Management" sh -c "! grep -q sfltool scripts/uninstall.sh"
mkdir -p "$home/Library/Containers/md.spacebar.viewer" "$home/Library/Containers/md.spacebar.preview"
check "--purge also removes the viewer's container, and only that container" \
  test "$(removed --purge)" = "$(printf '%s\n%s\n%s' "$app" "$support" "$home/Library/Containers/md.spacebar.viewer")"
check "without --purge the viewer's container stays" test "$(removed)" = "$app"
# Run from a private copy in a spacebar-update-* folder of TMPDIR, as the settings window starts it: the copy removes itself,
# and only with the marker. A dry run against the scratch HOME touches nothing else.
tmpd="$out/tmp"; mkdir -p "$tmpd/spacebar-update-self" "$tmpd/spacebar-update-kept"
cp scripts/uninstall.sh "$tmpd/spacebar-update-self/uninstall.sh"
cp scripts/uninstall.sh "$tmpd/spacebar-update-kept/uninstall.sh"
HOME="$home" TMPDIR="$tmpd/" SPACEBAR_UNINSTALL_SELF=1 sh "$tmpd/spacebar-update-self/uninstall.sh" --dry-run </dev/null >/dev/null 2>&1
HOME="$home" TMPDIR="$tmpd/" sh "$tmpd/spacebar-update-kept/uninstall.sh" --dry-run </dev/null >/dev/null 2>&1
check "started from the settings window, it removes its own private copy" test ! -e "$tmpd/spacebar-update-self"
check "without the marker its folder stays" test -e "$tmpd/spacebar-update-kept/uninstall.sh"
check "a dry run changes nothing" test -d "$app" -a -d "$support" -a -f "$home/Documents/keep.md" -a -d "$home/Library/Containers/md.spacebar.viewer"
exit $fail
