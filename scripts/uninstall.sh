#!/bin/sh
# spacebar uninstaller: https://github.com/patebry/spacebar
#
#   curl -fsSL https://raw.githubusercontent.com/patebry/spacebar/main/scripts/uninstall.sh | sh
#
# Quits ~/Applications/spacebar.app, unregisters its Quick Look extensions, and deletes it. Settings in
# ~/Library/Application Support/spacebar are kept unless you pass --purge. Safe to run more than once.
set -eu

APP_NAME=spacebar.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

usage() {
  cat <<'EOF'
Remove spacebar from ~/Applications.

usage: uninstall.sh [--purge] [--dry-run] [--no-register] [--help]

  --purge        also delete your settings and themes in ~/Library/Application Support/spacebar
  --dry-run      print what would change without changing anything
  --no-register  delete files only: skip quitting, pluginkit, lsregister and qlmanage
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

# Started from the settings window (SPACEBAR_UNINSTALL_SELF=1): removes the private copy this script runs from, but only a
# spacebar-update-* folder directly in $TMPDIR, where the app puts it.
remove_self() {
  [ "${SPACEBAR_UNINSTALL_SELF:-}" = 1 ] || return 0
  self_dir=${0%/uninstall.sh}
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

DEST="$HOME/Applications/$APP_NAME"
SUPPORT="$HOME/Library/Application Support/spacebar"
LEGACY_SUPPORT="$HOME/Library/Application Support/spacebar.md"

if [ -e "$DEST" ]; then
  if [ "$SKIP_REGISTER" != 1 ]; then
    if [ "$DRY_RUN" = 1 ]; then say "would quit the Quick Look extensions running from $DEST, their writers first"; else quit_extensions "$DEST"; fi
    run pkill -f "$(path_regex "$DEST")Contents/MacOS/" || true
    for appex in "$DEST"/Contents/PlugIns/*.appex; do
      [ -d "$appex" ] && { run pluginkit -r "$appex" || true; }
    done
    run "$LSREGISTER" -u "$DEST" || true
  fi
  run rm -rf "$DEST"
  if [ "$SKIP_REGISTER" != 1 ]; then
    run_quiet qlmanage -r || true
    run_quiet qlmanage -r cache || true
  fi
  [ "$DRY_RUN" = 1 ] || say "Removed $DEST"
else
  say "spacebar is not installed at $DEST"
fi

if [ "$PURGE" = 1 ]; then
  for dir in "$SUPPORT" "$LEGACY_SUPPORT"; do
    if [ -e "$dir" ]; then
      run rm -rf "$dir"
      [ "$DRY_RUN" = 1 ] || say "Removed $dir"
    fi
  done
  # Deleting another app's sandbox container makes macOS ask for permission, so it is left to you.
  for id in md.spacebar.preview md.spacebar.preview.folders; do
    if [ -e "$HOME/Library/Containers/$id" ]; then
      say "Left the sandbox container ~/Library/Containers/$id; delete it in Finder if you like."
    fi
  done
elif [ -e "$SUPPORT" ]; then
  say "Kept your settings in $SUPPORT (pass --purge to delete them)."
fi
}

main "$@"
