#!/bin/bash
# Builds and runs the Report a Problem checks, then checks the bundled uninstaller without running it: its syntax, and a
# --dry-run against a scratch HOME and /Applications that lists only what it would remove (no network, nothing opened,
# nothing deleted).
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
# A scratch /Applications too, so the real one is never looked at.
sys="$out/apps"
mkdir -p "$sys"
export SPACEBAR_SYSTEM_APPLICATIONS="$sys"
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
helper_steps() { dry "$@" | grep -n -e 'launchctl' -e 'Helpers/' -e 'tccutil' -e 'Quick Look extensions' -e 'rm -rf' | cut -d: -f2-; }
# The patterns pkill -f is given, as uninstall.sh escapes them: the bundle path, anchored, its dots escaped.
esc() { printf '^%s/' "$1" | sed 's/[][\.*$+?(){}|]/\\&/g'; }
helpers="$app/Contents/Helpers"
expected_helper="would run: launchctl bootout gui/$(id -u)/md.spacebar.helper
would run: pkill -f $(esc "$helpers/spacebar Helper.app")
would run: pkill -f $(esc "$helpers/spacebar Viewer.app")Contents/XPCServices/
  wait up to 6 s for that writer to exit, then run: pkill -f $(esc "$helpers/spacebar Viewer.app")
would run: tccutil reset Accessibility md.spacebar.helper
would run: tccutil reset All md.spacebar.viewer
would quit the Quick Look extensions running from $app, their writers first"
check "uninstall boots the helper's agent out, quits the helper, the viewer's writer and the viewer, then resets both permissions, all before the extensions" \
  test "$(helper_steps | head -7)" = "$expected_helper"
# Each pattern against the command lines the processes run with (ps shows the executable's full path).
matches() { printf '%s\n' "$2" | grep -qE "$1"; }
helper_cmd="$helpers/spacebar Helper.app/Contents/MacOS/SpacebarHelper"
viewer_cmd="$helpers/spacebar Viewer.app/Contents/MacOS/SpacebarViewer"
writer_cmd="$helpers/spacebar Viewer.app/Contents/XPCServices/md.spacebar.viewer.writer.xpc/Contents/MacOS/SpacebarWriter"
appex_cmd="$app/Contents/PlugIns/SpacebarPreview.appex/Contents/MacOS/SpacebarPreview"
other_cmd="$home/Applications/spacebar copy.app/Contents/Helpers/spacebar Viewer.app/Contents/MacOS/SpacebarViewer"
hp=$(esc "$helpers/spacebar Helper.app"); vp=$(esc "$helpers/spacebar Viewer.app")
check "the helper's pattern matches the helper and nothing else of spacebar's" \
  sh -c "$(declare -f matches); matches '$hp' '$helper_cmd' && ! matches '$hp' '$viewer_cmd' && ! matches '$hp' '$appex_cmd'"
check "the writer's pattern matches the viewer's writer only; the viewer's, the viewer and its writer" \
  sh -c "$(declare -f matches); matches '${vp}Contents/XPCServices/' '$writer_cmd' && ! matches '${vp}Contents/XPCServices/' '$viewer_cmd' && matches '$vp' '$viewer_cmd' && matches '$vp' '$writer_cmd' && ! matches '$vp' '$appex_cmd'"
check "neither matches a copy of spacebar installed elsewhere" sh -c "$(declare -f matches); ! matches '$vp' '$other_cmd' && ! matches '$hp' '$other_cmd'"
check "without --dry-run the same patterns are used" grep -q 'pkill -f "\${viewer}Contents/XPCServices/"' scripts/uninstall.sh
check "--no-register leaves launchd and TCC alone" sh -c "! (HOME='$home' sh scripts/uninstall.sh --dry-run --no-register </dev/null 2>&1 | grep -qe launchctl -e tccutil)"
check "the uninstaller never resets Background Task Management" sh -c "! grep -q sfltool scripts/uninstall.sh"
mkdir -p "$home/Library/Containers/md.spacebar.viewer" "$home/Library/Containers/md.spacebar.preview" "$home/Library/Logs"
touch "$home/Library/Logs/spacebar-helper.log" "$home/Library/Logs/spacebar-helper.lock" "$home/Library/Logs/other.log"
check "--purge also removes the helper's log and lock, and no container" \
  test "$(removed --purge)" = "$(printf '%s\n%s\n%s\n%s' "$app" "$support" "$home/Library/Logs/spacebar-helper.log" "$home/Library/Logs/spacebar-helper.lock")"
check "--purge lists the viewer's container and the extension's for you to delete" \
  sh -c "dry=\$(HOME='$home' sh scripts/uninstall.sh --dry-run --purge </dev/null 2>&1); for id in md.spacebar.viewer md.spacebar.preview; do printf '%s\n' \"\$dry\" | grep -qx \"Left the sandbox container ~/Library/Containers/\$id; delete it in Finder if you like.\" || exit 1; done"
check "without --purge the log and the containers stay" test "$(removed)" = "$app"
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

# A copy dragged into /Applications from spacebar.dmg goes the same way, after ~/Applications's when both are there; one this
# account cannot delete is left, named, and the run fails.
theirs="$sys/spacebar.app"
mkdir -p "$theirs/Contents/PlugIns/SpacebarPreview.appex"
check "both copies are removed, ~/Applications's first" test "$(removed)" = "$(printf '%s\n%s' "$app" "$theirs")"
check "each one's extensions are unregistered" sh -c "d=\$(HOME='$home' sh scripts/uninstall.sh --dry-run </dev/null 2>&1); for a in '$app' '$theirs'; do printf '%s\n' \"\$d\" | grep -qx \"would run: pluginkit -r \$a/Contents/PlugIns/SpacebarPreview.appex\" || exit 1; done"
quits_both() {
  local d; d=$(dry)
  for c in "$app" "$theirs"; do
    grep -qxF "would run: pkill -f $(esc "$c/Contents/Helpers/spacebar Helper.app")" <<<"$d" || return 1
    grep -qxF "would run: pkill -f $(esc "$c/Contents/Helpers/spacebar Viewer.app")Contents/XPCServices/" <<<"$d" || return 1
  done
}
check "each one's helper and viewer are quit" quits_both
check "the helper's agent and permissions are reset once" test "$(dry | grep -c -e 'launchctl bootout' -e 'tccutil')" = 3
rm -rf "$home/Applications"
check "a copy only in /Applications is removed" test "$(removed)" = "$theirs"
chmod 555 "$sys"
check "one this account cannot delete is left and named, and the run fails" sh -c "out=\$(HOME='$home' sh scripts/uninstall.sh --dry-run </dev/null 2>&1); code=\$?; [ \$code = 1 ] && printf '%s\n' \"\$out\" | grep -qx 'Left $theirs: this account cannot delete it. An administrator can move it to the Trash.' && ! printf '%s\n' \"\$out\" | grep -q -e 'rm -rf' -e 'pluginkit -r'"
chmod 755 "$sys"
chmod 555 "$theirs/Contents"
check "and so is one with a folder inside it this account cannot change" sh -c "HOME='$home' sh scripts/uninstall.sh --dry-run </dev/null 2>&1 | grep -q '^Left $theirs:'"
chmod 755 "$theirs/Contents"
ln -s "$theirs" "$home/Applications/spacebar.app" 2>/dev/null || { mkdir -p "$home/Applications"; ln -s "$theirs" "$home/Applications/spacebar.app"; }
check "a link in an install place is removed as a link, the copy it points to as itself" \
  test "$(dry | sed -n -e 's/^would run: rm -f //p' -e 's/^would run: rm -rf //p')" = "$(printf '%s\n%s' "$home/Applications/spacebar.app" "$theirs")"
check "and nothing is unregistered through the link" sh -c "! (HOME='$home' sh scripts/uninstall.sh --dry-run </dev/null 2>&1 | grep -q 'pluginkit -r $home/Applications/')"
rm "$home/Applications/spacebar.app"
# A real run, files only, in the scratch folders: a copy rm cannot delete (a locked file) is named, the other still goes.
mkdir -p "$app/Contents/PlugIns/SpacebarPreview.appex"
touch "$app/Contents/locked"
chflags uchg "$app/Contents/locked"
code=0
real=$(HOME="$home" sh scripts/uninstall.sh --no-register </dev/null 2>&1) || code=$?
chflags nouchg "$app/Contents/locked"
check "a copy rm cannot delete is named and the run goes on to the other, then fails" \
  sh -c "[ $code = 1 ] && printf '%s\n' \"\$1\" | grep -qx 'Could not delete $app. If macOS said your terminal was prevented from modifying apps, allow it in System' && [ ! -e '$theirs' ]" sh "$real"
rm -rf "$home/Applications"
check "with neither, it says where it looked" grep -qx "spacebar is not installed at $home/Applications/spacebar.app or $sys/spacebar.app" <<<"$(rm -rf "$theirs"; dry)"
exit $fail
