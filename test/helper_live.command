#!/bin/bash
# The Space helper, checked live in Finder by you: each step says what to do, you do it, and the helper's and viewer's logs
# grade it (with a yes or no from you where only your eyes can tell). This script sends no key, click or event of its own and
# opens no window; it reads logs, `--helper-status`, `launchctl` and `ioreg`, and makes a scratch folder of test files.
# Double-click it in Finder, or run it in Terminal:
#   test/helper_live.command            the whole checklist
#   test/helper_live.command 7 12       only those steps (numbers as listed below)
# After a restart, run it again: it checks that the helper came back by itself first.
set -uo pipefail
APP=${SPACEBAR_APP:-$HOME/Applications/spacebar.app}
EXE=$APP/Contents/MacOS/Spacebar
LABEL=md.spacebar.helper
STATE=$HOME/Library/Logs/spacebar-live.restart
tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "${tmp%/}/spacebar-live.XXXXXX")
log=$work/log.txt
passed=0 failed=0 skipped=0
trap '{ kill "$streamer"; wait "$streamer"; } 2>/dev/null; rm -rf "$work"' EXIT

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; failed=$((failed + 1)); }
skip() { printf '  SKIP %s\n' "$*"; skipped=$((skipped + 1)); }
grade() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }
ask() { local a; read -r -p "  $1 [y/n] " a </dev/tty; [[ $a == [Yy]* ]]; }
wait_done() { read -r -p "  Press Return here when done. " _ </dev/tty; sleep 0.5; }
mark() { mark_at=$(wc -l <"$log"); }
since() { tail -n +"$((mark_at + 1))" "$log"; }
count() { since | grep -c -- "$1" || true; }
status() { "$EXE" --helper-status 2>/dev/null; }
boot_time() { sysctl -n kern.boottime | sed -E 's/.*sec = ([0-9]+).*/\1/'; }

[ -x "$EXE" ] || { echo "spacebar is not installed at $APP"; exit 1; }
log stream --style compact --level info --predicate 'subsystem == "md.spacebar" AND (category == "helper" OR category == "viewer" OR category == "preview")' >"$log" 2>/dev/null &
streamer=$!
sleep 1

# Test files: Markdown with siblings for the sidebar, text for multi-select, and a small .dmg made without a file system.
files=$work/files
mkdir -p "$files"
for n in a b c d e; do printf '# Note %s\n\nText of note %s.\n' "$n" "$n" >"$files/$n.md"; done
printf 'one\ntwo\n' >"$files/plain.txt"
printf 'name,value\nx,1\n' >"$files/table.csv"
hdiutil create -size 1m -layout NONE -quiet "$files/disk.dmg" 2>/dev/null || true

after_restart() {
  bold "After the restart: the helper came back by itself"
  grade "launchd runs the helper" "launchctl print gui/$(id -u)/$LABEL 2>/dev/null | grep -q 'state = running'"
  grade "it answers, trusted, with its event tap" "status | grep -q 'trusted=true tap=true'"
  rm -f "$STATE"
}
if [ -f "$STATE" ] && [ "$(boot_time)" != "$(cat "$STATE")" ]; then after_restart; fi

steps=("$@")
want() { [ ${#steps[@]} -eq 0 ] || [[ " ${steps[*]} " == *" $1 "* ]]; }

bold "0. The helper is on"
s=$(status); echo "  $s" | tr '\n' ' '; echo
grade "--helper-status: trusted, tap" "grep -q 'trusted=true tap=true' <<<\"\$s\""
echo "  Test files are in $files (in Finder: Go > Go to Folder, and paste that path)."

if want 1; then
  bold "1. Finder's views"
  echo "  In a Finder window, press Space on a file, then Esc, in each view: icons, list, columns and gallery (⌘1 to ⌘4)."
  mark; wait_done
  n=$(count 'space show'); c=$(count 'close (key)')
  grade "a show in each of the 4 views (saw $n)" "[ $n -ge 4 ]"
  grade "each closed by its key (saw $c)" "[ $c -ge 4 ]"
  slow=$(since | sed -nE 's/.*space show n=[0-9]+ decided in ([0-9.]+)ms.*/\1/p' | awk '$1 > 60' | wc -l | tr -d ' ')
  grade "every Space decided within 60 ms ($(since | sed -nE 's/.*decided in ([0-9.]+)ms.*/\1/p' | tr '\n' ' ')ms)" "[ $slow = 0 ]"
fi

if want 2; then
  bold "2. The Desktop"
  echo "  Click a file on the Desktop, press Space, then Esc."
  mark; wait_done
  grade "a show from the Desktop" "[ $(count 'space show') -ge 1 ]"
fi

if want 3; then
  bold "3. Rename and search keep their Space"
  echo "  Select a file, press Return to rename it, type a space, then Esc. Then press ⌘F and type a space in the search field."
  mark; wait_done
  grade "no panel opened" "[ $(count 'space show') = 0 ]"
  grade "the helper saw the text field and passed the Space (saw $(count 'text-focus'))" "[ $(count 'text-focus') -ge 2 ]"
fi

if want 4; then
  bold "4. One press: Space opens, Space closes; Space opens, Esc closes"
  echo "  On a file: Space, Space. Then Space, Esc."
  mark; wait_done
  grade "two shows, two closes by key" "[ $(count 'space show') -ge 2 ] && [ $(count 'close (key)') -ge 2 ]"
  if ask "Did each close take a single press?"; then pass "one press closes"; else fail "one press closes"; fi
fi

if want 5; then
  bold "5. Arrows in the sidebar"
  echo "  In $files, press Space on a.md, then ↓ three times, then Esc."
  mark; wait_done
  r=$(count 'rendered\[')
  grade "the panel showed each next file (saw $r renders)" "[ $r -ge 4 ]"
  if ask "Did the sidebar's cursor move and the panel follow, with Finder's selection left where it was?"; then pass "arrows drive the sidebar"; else fail "arrows drive the sidebar"; fi
fi

if want 6; then
  bold "6. Multi-select"
  echo "  In $files, select a.md, b.md and plain.txt (⌘-click), press Space, then Esc."
  mark; wait_done
  grade "one show of 3 files" "since | grep -q 'space show n=3'"
  if ask "Did the sidebar list just those three?"; then pass "sidebar of the selection"; else fail "sidebar of the selection"; fi
fi

if want 7; then
  bold "7. Hide and restore"
  echo "  Press Space on a PDF of several pages and scroll to page 3. Switch to another app (⌘Tab), then back to Finder."
  mark; wait_done
  grade "suspended, then restored" "since | grep -q 'suspend (' && since | grep -q 'restore'"
  grade "no restore failed" "! since | grep -q 'failed'"
  if ask "Did the PDF come back at page 3?"; then pass "a PDF keeps its page"; else fail "a PDF keeps its page"; fi
  echo "  Now press Space on a video, play it for a few seconds, switch to another app, then back to Finder; then Esc."
  mark; wait_done
  grade "suspended, then restored" "since | grep -q 'suspend (' && since | grep -q 'restore'"
  if ask "Did the video come back paused at the time it had reached?"; then pass "a video keeps its time"; else fail "a video keeps its time"; fi
fi

if want 8; then
  bold "8. A .dmg"
  if [ -f "$files/disk.dmg" ]; then
    echo "  In $files, press Space on disk.dmg, then Esc."
    mark; wait_done
    grade "a show" "[ $(count 'space show') -ge 1 ]"
    if ask "Did its card say the format (uncompressed) and that it is not encrypted?"; then pass "the .dmg card"; else fail "the .dmg card"; fi
  else
    skip "hdiutil made no test image"
  fi
fi

if want 9; then
  bold "9. Camera RAW"
  raw=$(mdfind -onlyin "$HOME" 'kMDItemContentTypeTree == "public.camera-raw-image"' 2>/dev/null | head -1)
  if [ -n "$raw" ]; then
    echo "  Press Space on $raw, then Esc."
    mark; wait_done
    grade "shown by the native image view" "since | grep -q 'show bitmap'"
    if ask "Was the photo drawn, turned the right way?"; then pass "RAW"; else fail "RAW"; fi
  else
    skip "no RAW file under your home folder"
  fi
fi

if want 10; then
  bold "10. ⌘Y is left to Apple"
  echo "  Select a file and press ⌘Y; close Apple's Quick Look with Esc."
  mark; wait_done
  grade "spacebar's panel did not open" "[ $(count 'space show') = 0 ]"
  if ask "Did Apple's Quick Look open?"; then pass "⌘Y opens Apple's Quick Look"; else fail "⌘Y opens Apple's Quick Look"; fi
fi

if want 11; then
  bold "11. Secure input"
  echo "  In Terminal, turn on Terminal > Secure Keyboard Entry. Click a file in Finder and press Space, then Esc."
  mark; wait_done
  grade "secure input was on" "ioreg -l -w 0 | grep -q kCGSSessionSecureInputPID"
  grade "spacebar's panel did not open" "[ $(count 'space show') = 0 ]"
  grade "--helper-status still answers" "status | grep -q 'helper: pid'"
  echo "  Turn Secure Keyboard Entry off again."
fi

if want 12; then
  bold "12. After an update, the helper is back within about 20 s"
  echo "  Update spacebar now: its Update button, the install command, or ./build.sh in another terminal. Press Return as it"
  echo "  finishes installing."
  wait_done
  swapped=$(stat -f %m "$APP"); t=0
  until status | grep -q 'trusted=true tap=true' || [ $t -ge 90 ]; do sleep 1; t=$((t + 1)); done
  back=$(( $(date +%s) - swapped ))
  grade "trusted, with its tap, $back s after the app was replaced (target about 20 s)" "status | grep -q 'trusted=true tap=true' && [ $back -le 30 ]"
  tail -n 5 "$HOME/Library/Logs/spacebar-helper.log" 2>/dev/null | sed 's/^/    /'
fi

if want 13; then
  bold "13. After a restart, the helper is running"
  boot_time >"$STATE"
  echo "  Restart the Mac, then run this script again: it checks the helper first, before the other steps."
fi

bold "Done: $passed passed, $failed failed, $skipped skipped"
[ "$failed" = 0 ]
