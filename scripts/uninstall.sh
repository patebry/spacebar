#!/bin/sh
# spacebar uninstaller: https://github.com/patebry/spacebar
#
#   curl -fsSL https://spacebar.patebryant.com/uninstall.sh | sh
#   curl -fsSL https://spacebar.patebryant.com/uninstall.sh | sh -s -- --purge    (options go after sh -s --)
#
# Stops the Space helper and quits its viewer, resets the permissions macOS keeps for them, quits
# ~/Applications/spacebar.app and /Applications/spacebar.app, whichever are there, unregisters their Quick Look extensions,
# and deletes them. A copy this account cannot delete is left in place, and named. Settings in
# ~/Library/Application Support/spacebar and the helper's log are kept unless you pass --purge; sandbox containers are
# listed, not deleted. Safe to run more
# than once.
set -eu

APP_NAME=spacebar.app
HELPER_LABEL=md.spacebar.helper
VIEWER_ID=md.spacebar.viewer
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

usage() {
  cat <<'EOF'
Remove spacebar from ~/Applications and /Applications.

usage: uninstall.sh [--purge] [--dry-run] [--no-register] [--help]

  --purge        also delete your settings and themes in ~/Library/Application Support/spacebar and the Space
                 helper's log in ~/Library/Logs; sandbox containers are listed for you to delete
  --dry-run      print what would change without changing anything
  --no-register  delete files only: skip quitting, launchctl, tccutil, pluginkit, lsregister and qlmanage
                 (or set SPACEBAR_SKIP_REGISTER=1)
  --help         show this help
EOF
}

say() { printf '%s\n' "$*"; }
run() {
  if [ "$DRY_RUN" = 1 ]; then say "would run: $*"; else "$@"; fi
}
run_quiet() {
  if [ "$DRY_RUN" = 1 ]; then say "would run: $*"; else "$@" >/dev/null 2>&1; fi
}
path_regex() { printf '^%s/' "$1" | sed 's/[][\.*$+?(){}|]/\\&/g'; }

# quit_extensions <bundle path>: as in install.sh. The writers go first and get up to 6 seconds to finish a write, then the
# extensions: a writer left running would put settings.json back after --purge.
quit_extensions() {
  writers="$(path_regex "$1")Contents/PlugIns/[^/]*/Contents/XPCServices/"
  pkill -f "$writers" || true
  tries=0
  while [ "$tries" -lt 30 ] && pgrep -f "$writers" >/dev/null 2>&1; do
    sleep 0.2
    tries=$((tries + 1))
  done
  pkill -f "$(path_regex "$1")Contents/PlugIns/" || true
}

# quit_viewer <bundle path>: as in install.sh, the Space helper's viewer, its writer first.
quit_viewer() {
  viewer=$(path_regex "$1/Contents/Helpers/spacebar Viewer.app")
  if [ "$DRY_RUN" = 1 ]; then
    say "would run: pkill -f ${viewer}Contents/XPCServices/"
    say "  wait up to 6 s for that writer to exit, then run: pkill -f $viewer"
    return 0
  fi
  pkill -f "${viewer}Contents/XPCServices/" || true
  tries=0
  while [ "$tries" -lt 30 ] && pgrep -f "${viewer}Contents/XPCServices/" >/dev/null 2>&1; do
    sleep 0.2
    tries=$((tries + 1))
  done
  pkill -f "$viewer" || true
}

# removable <bundle path>: whether this account can delete it: its folder, and every folder inside it, writable.
removable() {
  [ -w "${1%/*}" ] || return 1
  [ -z "$(find "$1" -type d 2>&1 | while IFS= read -r d; do [ -d "$d" ] && [ -w "$d" ] || { printf x; break; }; done)" ]
}

# Started from the settings window (SPACEBAR_UNINSTALL_SELF=1): removes the private copy this script runs from, but only a
# spacebar-update-* folder directly in $TMPDIR, where the app puts it.
remove_self() {
  [ "${SPACEBAR_UNINSTALL_SELF:-}" = 1 ] || return 0
  self_dir=${0%/*}
  case ${self_dir##*/} in
    spacebar-update-*)
      parent=$(cd "${self_dir%/*}" 2>/dev/null && pwd -P)
      tmp=$(cd "${TMPDIR:-/nonexistent}" 2>/dev/null && pwd -P)
      [ "$self_dir" != "$0" ] && [ -n "$parent" ] && [ "$parent" = "$tmp" ] && rm -rf "$self_dir"
      ;;
  esac
  return 0
}
trap remove_self EXIT

# Everything runs from main, called on the last line, so a download cut short by the network runs nothing.
main() {
PURGE=0
DRY_RUN=0
SKIP_REGISTER=${SPACEBAR_SKIP_REGISTER:-0}
while [ $# -gt 0 ]; do
  case $1 in
    --purge) PURGE=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --no-register) SKIP_REGISTER=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# Root's HOME may be kept by sudo: launchctl, tccutil and pluginkit would act on root's, not the user's.
[ "$(id -u)" != 0 ] || { echo "error: run this as yourself, without sudo: it removes spacebar for your account." >&2; exit 1; }

SUPPORT="$HOME/Library/Application Support/spacebar"
LEGACY_SUPPORT="$HOME/Library/Application Support/spacebar.md"
# Overridable only so a copy there can be tested without touching /Applications.
SYSTEM_APPS=${SPACEBAR_SYSTEM_APPLICATIONS:-/Applications}

# The copies there are, ~/Applications's first, and links (a dangling one included). With none, a helper still running
# from ~/Applications is quit all the same.
set --
for c in "$HOME/Applications/$APP_NAME" "$SYSTEM_APPS/$APP_NAME"; do
  if [ -e "$c" ] || [ -L "$c" ]; then set -- "$@" "$c"; fi
done
FOUND=$#
[ "$FOUND" -gt 0 ] || set -- "$HOME/Applications/$APP_NAME"
LEFT=0

# The Space helper first, so nothing starts the viewer again: its launchd agent out, the viewer quit, then what macOS keeps
# for them, the helper's Accessibility grant and every permission of the viewer's. Its Login Item entry goes when the app
# does; the Background Task Management database is never reset.
if [ "$SKIP_REGISTER" != 1 ]; then
  run_quiet launchctl bootout "gui/$(id -u)/$HELPER_LABEL" || true
  for DEST in "$@"; do
    # A helper still running from the bundle (its job gone, launchd not yet done with it) goes too.
    run_quiet pkill -f "$(path_regex "$DEST/Contents/Helpers/spacebar Helper.app")" || true
    quit_viewer "$DEST"
  done
  run_quiet tccutil reset Accessibility "$HELPER_LABEL" || true
  run_quiet tccutil reset All "$VIEWER_ID" || true
fi

[ "$FOUND" -gt 0 ] || say "spacebar is not installed at $HOME/Applications/$APP_NAME or $SYSTEM_APPS/$APP_NAME"
for DEST in "$@"; do
  [ -e "$DEST" ] || [ -L "$DEST" ] || continue
  # Only the link goes: the copy it points to is not one of these two, or is removed as itself.
  if [ -L "$DEST" ]; then
    if run rm -f "$DEST"; then
      [ "$DRY_RUN" = 1 ] || say "Removed the link $DEST"
    else
      say "Left the link $DEST: this account cannot delete it."
      LEFT=1
    fi
    continue
  fi
  if ! removable "$DEST"; then
    say "Left $DEST: this account cannot delete it. An administrator can move it to the Trash."
    LEFT=1
    continue
  fi
  if [ "$SKIP_REGISTER" != 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then say "would quit the Quick Look extensions running from $DEST, their writers first"; else quit_extensions "$DEST"; fi
    run pkill -f "$(path_regex "$DEST")Contents/MacOS/" || true
    for appex in "$DEST"/Contents/PlugIns/*.appex; do
      [ -d "$appex" ] && { run pluginkit -r "$appex" || true; }
    done
    run "$LSREGISTER" -u "$DEST" || true
  fi
  if ! run rm -rf "$DEST"; then
    say "Could not delete $DEST. If macOS said your terminal was prevented from modifying apps, allow it in System"
    say "Settings > Privacy & Security > App Management, then run this again."
    LEFT=1
    continue
  fi
  if [ "$SKIP_REGISTER" != 1 ]; then
    run_quiet qlmanage -r || true
    run_quiet qlmanage -r cache || true
  fi
  [ "$DRY_RUN" = 1 ] || say "Removed $DEST"
done

if [ "$PURGE" = 1 ]; then
  for dir in "$SUPPORT" "$LEGACY_SUPPORT" "$HOME/Library/Logs/spacebar-helper.log" "$HOME/Library/Logs/spacebar-helper.lock"; do
    if [ -e "$dir" ]; then
      run rm -rf "$dir"
      [ "$DRY_RUN" = 1 ] || say "Removed $dir"
    fi
  done
  # Deleting another app's sandbox container makes macOS ask for permission, so it is left to you.
  for id in md.spacebar.preview md.spacebar.preview.folders "$VIEWER_ID"; do
    if [ -e "$HOME/Library/Containers/$id" ]; then
      say "Left the sandbox container ~/Library/Containers/$id; delete it in Finder if you like."
    fi
  done
elif [ -e "$SUPPORT" ]; then
  say "Kept your settings in $SUPPORT (pass --purge to delete them)."
fi
[ "$LEFT" = 0 ] || exit 1
}

main "$@"
