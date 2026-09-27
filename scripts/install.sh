#!/bin/sh
# spacebar installer: https://github.com/patebry/spacebar
#
#   curl -fsSL https://spacebar.patebryant.com/install.sh | sh
#
# What this does, in order:
#   1. Checks for macOS 13 or later.
#   2. Downloads spacebar.zip and spacebar.zip.sha256 from the latest GitHub release (or SPACEBAR_VERSION) with curl
#      into a temporary folder, and stops unless the SHA-256 matches. It makes no GitHub API calls, so it is never
#      rate-limited.
#   3. Unzips the new spacebar.app and copies it into ~/Applications as .spacebar.app.new (no sudo).
#   4. If ~/Applications/spacebar.app exists: quits that copy and unregisters its Quick Look extensions, renames it to
#      .spacebar.app.old, quits its extensions still running, renames the new copy into its place, then deletes
#      .spacebar.app.old. If the new copy cannot be moved in, the old one is put back. Nothing outside those three exact
#      paths is removed (and, when spacebar's Update button started this run, the private copy of this script it ran).
#   5. Registers it with Launch Services and pluginkit, turns on the Markdown preview extension, and resets
#      Quick Look's cache.
#   6. Lists any other Quick Look extensions that claim Markdown and are turned on, and warns about a second copy in
#      /Applications. It never turns anything off or deletes anything else itself.
# Running it again reinstalls the same or a newer version. --dry-run downloads and verifies, then changes nothing.
set -eu

REPO=patebry/spacebar
INSTALL_URL=https://spacebar.patebryant.com/install.sh
APP_NAME=spacebar.app
APPEX_ID=md.spacebar.preview
FOLDERS_ID=md.spacebar.preview.folders
# A stalled connection gives up instead of hanging the install.
CURL_LIMITS="--connect-timeout 15 --max-time 600"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
QL_SETTINGS='x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview'

usage() {
  cat <<'EOF'
Install spacebar, the Quick Look previewer for Markdown, into ~/Applications.

usage: install.sh [--version vX.Y.Z] [--dry-run] [--no-register] [--no-prompt] [--help]

  --version vX.Y.Z  install this release instead of the latest (or set SPACEBAR_VERSION)
  --dry-run         download and verify, then print what would change; changes and removes nothing
  --no-register     install the files only: skip quitting, lsregister, pluginkit and qlmanage
                    (or set SPACEBAR_SKIP_REGISTER=1)
  --no-prompt       never ask to open System Settings
  --help            show this help

Environment:
  SPACEBAR_VERSION      release tag to install, e.g. v0.1.0
  SPACEBAR_RELEASE_URL  base URL holding spacebar.zip and spacebar.zip.sha256 (overrides GitHub)
  SPACEBAR_SKIP_REGISTER=1  same as --no-register
EOF
}

say() { printf '%s\n' "$*"; }
# quote <word>: the word, single-quoted only when a shell would need it.
quote() {
  case $1 in
    '' | *[!A-Za-z0-9_./:=@+,-]*) printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")" ;;
    *) printf '%s' "$1" ;;
  esac
}
# The command that repeats this run: same options, same SPACEBAR_* settings.
retry_command() {
  envs=""
  [ -n "${SPACEBAR_RELEASE_URL:-}" ] && envs="${envs}SPACEBAR_RELEASE_URL=$(quote "$SPACEBAR_RELEASE_URL") "
  [ -n "${SPACEBAR_VERSION:-}" ] && envs="${envs}SPACEBAR_VERSION=$(quote "$SPACEBAR_VERSION") "
  [ "${SPACEBAR_SKIP_REGISTER:-0}" = 1 ] && envs="${envs}SPACEBAR_SKIP_REGISTER=1 "
  if [ -n "$ARGS" ]; then
    printf 'curl -fsSL %s | %ssh -s --%s' "$INSTALL_URL" "$envs" "$ARGS"
  else
    printf 'curl -fsSL %s | %ssh' "$INSTALL_URL" "$envs"
  fi
}
fail() {
  printf 'error: %s\n' "$*" >&2
  printf 'To try again, run:\n  %s\n' "$(retry_command)" >&2
  exit 1
}
run() {
  if [ "$DRY_RUN" = 1 ]; then say "would run: $*"; else "$@"; fi
}
run_quiet() {
  if [ "$DRY_RUN" = 1 ]; then say "would run: $*"; else "$@" >/dev/null 2>&1; fi
}
# The bundle path as an anchored regex, so pkill/pgrep match processes running from this exact bundle only.
path_regex() { printf '^%s/' "$1" | sed 's/[][\.*$+?(){}|]/\\&/g'; }

# quit_extensions <bundle path>: quits the Quick Look extensions running from it. Their writers go first and are given up to
# 6 seconds: a writer on SIGTERM finishes the file write it is in before it exits, and the extension would retry a lost one.
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

# Re-registers a copy that was unregistered for a swap that did not happen.
reregister() {
  [ "$SKIP_REGISTER" = 1 ] && return 0
  "$LSREGISTER" -f -R "$1" || true
  for appex in "$1"/Contents/PlugIns/*.appex; do
    [ -d "$appex" ] && { pluginkit -a "$appex" || true; }
  done
  return 0
}

# Runs on every exit. Removes only what this run created, and puts the previous copy back if a swap was cut short.
cleanup() {
  code=$?
  # A failing step here must not cut the rest short.
  set +e
  if [ "$SWAPPING" = 1 ] && [ ! -e "$DEST" ] && [ -e "$OLD" ]; then
    mv "$OLD" "$DEST" && printf 'Put the previous copy back at %s\n' "$DEST" >&2
  fi
  if [ "$UNREGISTERED" = 1 ] && [ -e "$DEST" ]; then reregister "$DEST"; fi
  if [ "$MADE_NEW" = 1 ]; then rm -rf "$NEW"; fi
  if [ -n "$TMP" ]; then rm -rf "$TMP"; fi
  # Started by spacebar's Update button: record how the run ended for the preview, and remove the private copy it ran.
  if [ -n "${SPACEBAR_UPDATE_STATUS:-}" ]; then
    v=${VERSION#v}
    case $v in '' | *[!0-9.]*) v="" ;; esac
    [ -n "$v" ] && printf '{"version":"%s","exitStatus":%d,"finishedAt":%s}\n' "$v" "$code" "$(date +%s)" >"$SPACEBAR_UPDATE_STATUS.tmp" &&
      mv -f "$SPACEBAR_UPDATE_STATUS.tmp" "$SPACEBAR_UPDATE_STATUS"
    # Only a spacebar-update-* folder directly in $TMPDIR, where the writer puts the copy.
    self_dir=${0%/install.sh}
    case ${self_dir##*/} in
      spacebar-update-*)
        parent=$(cd "${self_dir%/*}" 2>/dev/null && pwd -P)
        tmp=$(cd "${TMPDIR:-/nonexistent}" 2>/dev/null && pwd -P)
        [ "$self_dir" != "$0" ] && [ -n "$parent" ] && [ "$parent" = "$tmp" ] && rm -rf "$self_dir"
        ;;
    esac
  fi
  return 0
}

# Everything runs from main, called on the last line, so a download cut short by the network runs nothing.
main() {
ARGS=""
for a in "$@"; do ARGS="$ARGS $(quote "$a")"; done
VERSION=${SPACEBAR_VERSION:-}
DRY_RUN=0
SKIP_REGISTER=${SPACEBAR_SKIP_REGISTER:-0}
PROMPT=1
while [ $# -gt 0 ]; do
  case $1 in
    --version) [ $# -ge 2 ] || { echo "--version needs a tag" >&2; exit 2; }; VERSION=$2; shift ;;
    --version=*) VERSION=${1#--version=} ;;
    --dry-run) DRY_RUN=1 ;;
    --no-register) SKIP_REGISTER=1 ;;
    --no-prompt) PROMPT=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

# 1. macOS 13 or later.
[ "$(uname -s)" = Darwin ] || { echo "error: spacebar is a macOS app." >&2; exit 1; }
os=$(sw_vers -productVersion)
[ "${os%%.*}" -ge 13 ] || { echo "error: spacebar needs macOS 13 or later (this Mac has $os)." >&2; exit 1; }

DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_NAME"
NEW="$DEST_DIR/.$APP_NAME.new"
OLD="$DEST_DIR/.$APP_NAME.old"
# Where a second, unmanaged copy would sit. Overridable only so the warning can be tested without touching /Applications.
SYSTEM_APPS=${SPACEBAR_SYSTEM_APPLICATIONS:-/Applications}
TMP=""
MADE_NEW=0
SWAPPING=0
UNREGISTERED=0
trap cleanup EXIT
trap 'exit 130' INT TERM

# 2. Resolve the release and download it. github.com/<repo>/releases/latest/download/<asset> redirects to the newest
# release's asset without the rate-limited API. The tag shown comes from where /releases/latest redirects.
if [ -n "${SPACEBAR_RELEASE_URL:-}" ]; then
  BASE=${SPACEBAR_RELEASE_URL%/}
  [ -n "$VERSION" ] || VERSION="(from $BASE)"
elif [ -n "$VERSION" ]; then
  BASE="https://github.com/$REPO/releases/download/$VERSION"
else
  BASE="https://github.com/$REPO/releases/latest/download"
  landed=$(curl -fsSIL $CURL_LIMITS -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null || true)
  case $landed in
    */releases/tag/?*) VERSION="${landed##*/releases/tag/} (latest)" ;;
    *) VERSION="(latest)" ;;
  esac
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/spacebar-install.XXXXXX")

say "Downloading spacebar $VERSION"
curl -fSL $CURL_LIMITS --progress-bar -o "$TMP/spacebar.zip" "$BASE/spacebar.zip" || fail "download failed: $BASE/spacebar.zip"
curl -fsSL $CURL_LIMITS -o "$TMP/spacebar.zip.sha256" "$BASE/spacebar.zip.sha256" || fail "download failed: $BASE/spacebar.zip.sha256"

expected=$(awk '{ print $1; exit }' "$TMP/spacebar.zip.sha256")
actual=$(shasum -a 256 "$TMP/spacebar.zip" | awk '{ print $1 }')
[ -n "$expected" ] && [ "$expected" = "$actual" ] ||
  fail "checksum mismatch (expected ${expected:-nothing}, got $actual). Nothing was installed."
say "Checksum OK ($actual)"

ditto -x -k "$TMP/spacebar.zip" "$TMP/unpacked" || fail "could not unpack spacebar.zip. Nothing was installed."
[ -d "$TMP/unpacked/$APP_NAME/Contents/PlugIns" ] || fail "the download does not contain $APP_NAME. Nothing was installed."

if [ "$DRY_RUN" = 1 ]; then
  if [ ! -e "$DEST" ] && [ -e "$OLD" ]; then
    say "would move $OLD back to $DEST (left by an interrupted install), then replace it"
  fi
  say "would copy $APP_NAME to $NEW"
  if [ -e "$DEST" ] || [ -e "$OLD" ]; then
    say "Would replace $DEST"
    if [ "$SKIP_REGISTER" != 1 ]; then
      say "would run: pkill -f $(path_regex "$DEST")Contents/MacOS/"
      for appex in "$DEST"/Contents/PlugIns/*.appex; do
        [ -d "$appex" ] && say "would run: pluginkit -r $appex"
      done
      say "would run: $LSREGISTER -u $DEST"
    fi
    say "would move $DEST to $OLD, move $NEW to $DEST, then delete $OLD"
    if [ "$SKIP_REGISTER" != 1 ]; then
      say "after the first move, would run: pkill -f $(path_regex "$DEST")Contents/PlugIns/[^/]*/Contents/XPCServices/,"
      say "  wait up to 6 s for those writers to exit, then run: pkill -f $(path_regex "$DEST")Contents/PlugIns/ (and the same for $OLD)"
    fi
  else
    say "would move $NEW to $DEST"
  fi
else
  # A run killed mid-swap can leave the previous copy at .old with nothing installed: put it back first.
  if [ ! -e "$DEST" ] && [ -e "$OLD" ]; then
    mv "$OLD" "$DEST" || fail "could not restore $OLD to $DEST."
  fi

  # 3. Copy the new app beside the old one first, so a failed copy leaves the old one working.
  mkdir -p "$DEST_DIR" || fail "could not create $DEST_DIR. Nothing was installed."
  rm -rf "$NEW" "$OLD" || fail "could not remove $NEW or $OLD. Nothing was installed."
  MADE_NEW=1
  ditto "$TMP/unpacked/$APP_NAME" "$NEW" || fail "could not copy the app into $DEST_DIR. Nothing was installed."

  # 4. Swap it in at exactly ~/Applications/spacebar.app: old copy aside, new copy in, then the old copy deleted.
  if [ -e "$DEST" ]; then
    say "Replacing $DEST"
    if [ "$SKIP_REGISTER" != 1 ]; then
      UNREGISTERED=1
      pkill -f "$(path_regex "$DEST")Contents/MacOS/" || true
      for appex in "$DEST"/Contents/PlugIns/*.appex; do
        [ -d "$appex" ] && { pluginkit -r "$appex" || true; }
      done
      "$LSREGISTER" -u "$DEST" || true
    fi
    SWAPPING=1
    if ! mv "$DEST" "$OLD"; then
      SWAPPING=0
      fail "could not move the previous copy aside; it is still installed at $DEST."
    fi
    # Quick Look extensions (and their writers) still running the old code would keep serving it from a deleted bundle.
    if [ "$SKIP_REGISTER" != 1 ]; then
      quit_extensions "$DEST"
      quit_extensions "$OLD"
    fi
    if ! mv "$NEW" "$DEST"; then
      mv "$OLD" "$DEST" || fail "could not move the new copy in, nor put the previous one back: it is at $OLD."
      SWAPPING=0
      fail "could not move the new copy into $DEST. The previous copy was put back."
    fi
    SWAPPING=0
    UNREGISTERED=0
    MADE_NEW=0
    rm -rf "$OLD" || say "note: could not delete $OLD; delete it yourself."
  else
    mv "$NEW" "$DEST" || fail "could not move the new copy into $DEST."
    MADE_NEW=0
  fi
fi

# 5. Register.
if [ "$SKIP_REGISTER" = 1 ]; then
  say "Skipped registration (--no-register)."
else
  run "$LSREGISTER" -f -R "$DEST"
  run pluginkit -a "$DEST/Contents/PlugIns/SpacebarPreview.appex"
  run pluginkit -a "$DEST/Contents/PlugIns/SpacebarFolders.appex"
  run pluginkit -e use -i "$APPEX_ID"
  # Folder previews are on by default (Settings > Sidebar); the folders extension stays off only if they were turned off.
  settings="$HOME/Library/Application Support/spacebar/settings.json"
  [ -e "${settings%/*}" ] || settings="$HOME/Library/Application Support/spacebar.md/settings.json"
  if grep -qE '"folderMode"[[:space:]]*:[[:space:]]*false' "$settings" 2>/dev/null && grep -qE '"version"[[:space:]]*:[[:space:]]*([2-9]|[1-9][0-9])' "$settings"; then
    run pluginkit -e ignore -i "$FOLDERS_ID"
  else
    run pluginkit -e use -i "$FOLDERS_ID"
  fi
  run_quiet qlmanage -r || true
  run_quiet qlmanage -r cache || true
  if [ "$DRY_RUN" != 1 ] && pgrep -f "$(path_regex "$DEST")Contents/PlugIns/" >/dev/null 2>&1; then
    say "note: a Quick Look preview from the old version is still open; close it to load the new one."
  fi
fi

# 6. Other Quick Look extensions that claim Markdown: macOS picks one per file type, and it may not pick spacebar.
# Read-only: pluginkit -m only lists what is registered.
rivals=""
if command -v pluginkit >/dev/null 2>&1; then
  # pluginkit prints a header per extension, "<mark> <id>(<version>)" with mark "-" when it is off, then tab-indented fields.
  records=$(pluginkit -mAvvv -p com.apple.quicklook.preview 2>/dev/null | awk '
    /^\t/ { if ($1 == "Path" && $2 == "=") { p = $0; sub(/^\t *Path = /, "", p); print m "\t" id "\t" p }; next }
    /\(/ { m = substr($0, 1, 1); id = $0; sub(/^[-+=! ]*/, "", id); sub(/\(.*/, "", id) }')
  tab=$(printf '\t')
  while IFS="$tab" read -r mark id path; do
    case $id in md.spacebar*|"") continue ;; esac
    [ "$mark" = "-" ] && continue
    plist="$path/Contents/Info.plist"
    [ -f "$plist" ] || continue
    if plutil -extract NSExtension.NSExtensionAttributes.QLSupportedContentTypes json -o - "$plist" 2>/dev/null |
       grep -qi markdown; then
      rivals="$rivals
  $id  $path"
    fi
  done <<EOF
$records
EOF
fi

say ""
if [ "$DRY_RUN" = 1 ]; then
  say "Dry run: nothing was changed."
else
  say "Installed spacebar $VERSION to $DEST"
fi
if [ -e "$SYSTEM_APPS/$APP_NAME" ]; then
  say ""
  say "warning: there is another copy at $SYSTEM_APPS/$APP_NAME. Both copies claim Markdown files, so Quick Look"
  say "may use either one. This installer manages only $DEST and has left the other copy alone;"
  say "delete it yourself if you do not need it."
fi
if [ -n "$rivals" ]; then
  say ""
  say "Other Quick Look extensions that preview Markdown are turned on:$rivals"
  say "If Markdown does not open in spacebar, turn the others off in System Settings > General >"
  say "Login Items & Extensions > Quick Look (macOS 13-14: Privacy & Security > Extensions > Quick Look),"
  say "or run:  pluginkit -e ignore -i <id>"
  if [ "$PROMPT" = 1 ] && [ "$DRY_RUN" != 1 ] && [ -t 1 ] && (: </dev/tty) 2>/dev/null; then
    printf 'Open Quick Look extension settings now? [y/N] '
    read -r answer </dev/tty || answer=
    case $answer in [Yy]*) open "$QL_SETTINGS" || true ;; esac
  fi
fi
say ""
say "Next: select a .md file in Finder and press Space."
say "Settings: open ~/Applications/spacebar.app"
say "Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/uninstall.sh | sh"
}

main "$@"
