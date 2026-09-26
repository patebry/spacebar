#!/bin/sh
# spacebar installer: https://github.com/patebry/spacebar
#
#   curl -fsSL https://spacebar.patebryant.com/install.sh | sh
#
# What this does, in order:
#   1. Checks for macOS 13 or later.
#   2. Finds the latest release through the GitHub API (or SPACEBAR_VERSION), downloads spacebar.zip and
#      spacebar.zip.sha256 with curl into a temporary folder, and stops unless the SHA-256 matches.
#   3. Unzips the new spacebar.app and copies it into ~/Applications as .spacebar.app.new (no sudo).
#   4. If ~/Applications/spacebar.app exists: quits that copy, unregisters its Quick Look extensions, and deletes it.
#      Nothing outside that exact path is removed. Then renames the new copy into its place.
#   5. Registers it with Launch Services and pluginkit, turns on the Markdown preview extension, and resets
#      Quick Look's cache.
#   6. Lists any other Quick Look extensions that claim Markdown and are turned on, and tells you how to turn them
#      off. It never turns anything off itself.
# Running it again reinstalls the same or a newer version.
set -eu

REPO=patebry/spacebar
APP_NAME=spacebar.app
APPEX_ID=md.spacebar.preview
FOLDERS_ID=md.spacebar.preview.folders
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
QL_SETTINGS='x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview'

usage() {
  cat <<'EOF'
Install spacebar, the Quick Look previewer for Markdown, into ~/Applications.

usage: install.sh [--version vX.Y.Z] [--dry-run] [--no-register] [--no-prompt] [--help]

  --version vX.Y.Z  install this release instead of the latest (or set SPACEBAR_VERSION)
  --dry-run         download and verify, then print what would change without changing anything
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
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
run() {
  if [ "$DRY_RUN" = 1 ]; then say "would run: $*"; else "$@"; fi
}
run_quiet() {
  if [ "$DRY_RUN" = 1 ]; then say "would run: $*"; else "$@" >/dev/null 2>&1; fi
}
# The bundle path as an anchored regex, so pkill/pgrep match processes running from this exact bundle only.
path_regex() { printf '^%s/' "$1" | sed 's/[][\.*$+?(){}|]/\\&/g'; }

# Everything runs from main, called on the last line, so a download cut short by the network runs nothing.
main() {
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
[ "$(uname -s)" = Darwin ] || fail "spacebar is a macOS app."
os=$(sw_vers -productVersion)
[ "${os%%.*}" -ge 13 ] || fail "spacebar needs macOS 13 or later (this Mac has $os)."

DEST_DIR="$HOME/Applications"
DEST="$DEST_DIR/$APP_NAME"
NEW="$DEST_DIR/.$APP_NAME.new"

# 2. Resolve the release and download it.
if [ -n "${SPACEBAR_RELEASE_URL:-}" ]; then
  BASE=${SPACEBAR_RELEASE_URL%/}
  [ -n "$VERSION" ] || VERSION="(from $BASE)"
else
  if [ -z "$VERSION" ]; then
    latest=$(curl -fsSL -H 'Accept: application/vnd.github+json' "https://api.github.com/repos/$REPO/releases/latest") ||
      fail "could not get the latest release from the GitHub API (set SPACEBAR_VERSION to pick one)."
    VERSION=$(printf '%s\n' "$latest" | sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    [ -n "$VERSION" ] || fail "no published release found for $REPO."
  fi
  BASE="https://github.com/$REPO/releases/download/$VERSION"
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/spacebar-install.XXXXXX")
trap 'rm -rf "$TMP" "$NEW"' EXIT
trap 'exit 130' INT TERM

say "Downloading spacebar $VERSION"
curl -fSL --progress-bar -o "$TMP/spacebar.zip" "$BASE/spacebar.zip" || fail "download failed: $BASE/spacebar.zip"
curl -fsSL -o "$TMP/spacebar.zip.sha256" "$BASE/spacebar.zip.sha256" || fail "download failed: $BASE/spacebar.zip.sha256"

expected=$(awk '{ print $1; exit }' "$TMP/spacebar.zip.sha256")
actual=$(shasum -a 256 "$TMP/spacebar.zip" | awk '{ print $1 }')
[ -n "$expected" ] && [ "$expected" = "$actual" ] || fail "checksum mismatch (expected $expected, got $actual). Nothing was installed."
say "Checksum OK ($actual)"

ditto -x -k "$TMP/spacebar.zip" "$TMP/unpacked"
[ -d "$TMP/unpacked/$APP_NAME/Contents/PlugIns" ] || fail "the download does not contain $APP_NAME."

# 3. Copy the new app beside the old one first, so a failed copy leaves the old one working.
run mkdir -p "$DEST_DIR"
run rm -rf "$NEW"
run ditto "$TMP/unpacked/$APP_NAME" "$NEW"

# 4. Replace the previous copy at exactly ~/Applications/spacebar.app.
if [ -e "$DEST" ]; then
  say "Replacing $DEST"
  if [ "$SKIP_REGISTER" != 1 ]; then
    run pkill -f "$(path_regex "$DEST")Contents/MacOS/" || true
    for appex in "$DEST"/Contents/PlugIns/*.appex; do
      [ -d "$appex" ] && { run pluginkit -r "$appex" || true; }
    done
    run "$LSREGISTER" -u "$DEST" || true
  fi
  run rm -rf "$DEST"
fi
run mv "$NEW" "$DEST"

# 5. Register.
if [ "$SKIP_REGISTER" = 1 ]; then
  say "Skipped registration (--no-register)."
else
  run "$LSREGISTER" -f -R "$DEST"
  run pluginkit -a "$DEST/Contents/PlugIns/SpacebarPreview.appex"
  run pluginkit -a "$DEST/Contents/PlugIns/SpacebarFolders.appex"
  run pluginkit -e use -i "$APPEX_ID"
  # Folder previews are opt-in (Settings > Folders); the folders extension stays off unless they were turned on before.
  settings="$HOME/Library/Application Support/spacebar/settings.json"
  [ -e "${settings%/*}" ] || settings="$HOME/Library/Application Support/spacebar.md/settings.json"
  if grep -qE '"folderMode"[[:space:]]*:[[:space:]]*true' "$settings" 2>/dev/null; then
    run pluginkit -e use -i "$FOLDERS_ID"
  else
    run pluginkit -e ignore -i "$FOLDERS_ID"
  fi
  run_quiet qlmanage -r || true
  run_quiet qlmanage -r cache || true
  if pgrep -f "$(path_regex "$DEST")Contents/PlugIns/" >/dev/null 2>&1; then
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
