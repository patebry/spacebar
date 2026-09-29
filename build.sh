#!/bin/bash
# Build, sign, install and register spacebar without an Xcode project.
#   READ_ACCESS=abs-ro|abs-rw|none   sandbox file exception for files beside the document (default abs-ro)
#   PROBE=1                   compile the key-event instrumentation in Preview/Probe.swift (test builds only)
#   ARCHS="arm64 x86_64"      architectures to build (default both: a universal binary)
#   NO_INSTALL=1              build and sign only, into build/; never touches ~/Applications or pluginkit (also
#                             BUILD_ONLY=1 or --no-install). Used by CI.
#   INSTALL_DIR=...           default ~/Applications
#   VERSION=... BUILD_NUMBER=...  CFBundleShortVersionString (default 0.1.0) and CFBundleVersion (default 1)
#   SIGN_ID=...               codesigning identity; default the name in .sign-id (untracked), else the first valid local
#                             identity, else ad-hoc. SIGN_ID=- forces ad-hoc. A stable identity keeps TCC grants across rebuilds.
#   SIGN_KEYCHAIN=...         keychain file holding SIGN_ID, when it is not in the search list (CI's temporary keychain)
set -euo pipefail
cd "$(dirname "$0")"
for arg in "$@"; do
  case $arg in
    --no-install) NO_INSTALL=1 ;;
    *) echo "usage: ./build.sh [--no-install]" >&2; exit 2 ;;
  esac
done
[ "${BUILD_ONLY:-0}" = 1 ] && NO_INSTALL=1

APP_NAME=spacebar
APP_ID=md.spacebar
APPEX_ID=md.spacebar.preview
FOLDERS_ID=md.spacebar.preview.folders
APP_EXE=Spacebar
APPEX_EXE=SpacebarPreview
FOLDERS_EXE=SpacebarFolders
WRITER_EXE=SpacebarWriter           # each appex embeds its own writer as <appex ID>.writer
HELPER_ID=md.spacebar.helper        # the Space helper: a launchd agent holding the event tap (Helper/)
VIEWER_ID=md.spacebar.viewer        # the panel the helper opens, sandboxed like the preview extension (Viewer/)
HELPER_EXE=SpacebarHelper
VIEWER_EXE=SpacebarViewer
# Claimed only by this extension: `qlmanage -c $ROUTE_TYPE -p file` reaches it even where another extension claims markdown.
ROUTE_TYPE=md.spacebar.qlmanage
PREFERRED_SIGN_ID=$(head -n1 .sign-id 2>/dev/null || true)
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

READ_ACCESS=${READ_ACCESS:-abs-ro}
INSTALL_DIR=${INSTALL_DIR:-$HOME/Applications}
ARCHS=${ARCHS:-arm64 x86_64}
VERSION=${VERSION:-0.1.0}
BUILD_NUMBER=${BUILD_NUMBER:-1}
case $VERSION.$BUILD_NUMBER in *[!0-9.]*|.*|*..*) echo "VERSION and BUILD_NUMBER must be numeric, like 1.2.3 and 4" >&2; exit 2 ;; esac
MIN_OS=13.0
OUT=build
APP=$OUT/$APP_NAME.app
OBJ=$OUT/obj

if [ -z "${SIGN_ID:-}" ]; then
  identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
  if [ -n "$PREFERRED_SIGN_ID" ] && grep -qF "\"$PREFERRED_SIGN_ID\"" <<<"$identities"; then
    SIGN_ID=$PREFERRED_SIGN_ID
  else
    SIGN_ID=$(sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) ".*"$/\1/p' <<<"$identities" | head -1)
    SIGN_ID=${SIGN_ID:--}
  fi
fi

SIGN_ARGS=(--force --sign "$SIGN_ID" --timestamp=none)
[ -n "${SIGN_KEYCHAIN:-}" ] && SIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")

rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$OBJ"

# compile <output> <swiftc args...>: one slice per architecture, joined with lipo.
compile() {
  local out=$1; shift
  local slices=()
  for arch in $ARCHS; do
    local slice
    slice="$OBJ/$(basename "$out").$arch"
    xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos$MIN_OS" "$@" -o "$slice"
    slices+=("$slice")
  done
  mkdir -p "$(dirname "$out")"
  lipo -create "${slices[@]}" -output "$out"
}

# The types the preview extension claims and the app declares, from scripts/quicklook-types.txt (its header says how).
CLAIMS=()
IMPORTED_TYPES=
seen_exts=" "
while read -r verb exts conforms desc; do
  case $verb in
    ''|'#'*) continue ;;
    claim)
      [[ $exts =~ ^[A-Za-z0-9.-]+$ && -z $conforms ]] || { echo "quicklook-types.txt: bad claim: $exts $conforms" >&2; exit 1; }
      CLAIMS+=("$exts") ;;
    declare)
      # Checked so each value goes into the plist, and through sed, as is.
      [[ $exts =~ ^[a-z0-9]+(,[a-z0-9]+)*$ && $conforms =~ ^[a-z0-9.-]+(,[a-z0-9.-]+)*$ && $desc =~ ^[A-Za-z0-9][A-Za-z0-9\ .+-]*$ ]] \
        || { echo "quicklook-types.txt: bad declaration: $exts $conforms $desc" >&2; exit 1; }
      for ext in ${exts//,/ }; do
        [[ $seen_exts == *" $ext "* ]] && { echo "quicklook-types.txt: .$ext declared twice" >&2; exit 1; }
        seen_exts+="$ext "
      done
      CLAIMS+=("md.spacebar.type.${exts%%,*}")
      IMPORTED_TYPES+="<dict><key>UTTypeIdentifier</key><string>md.spacebar.type.${exts%%,*}</string><key>UTTypeDescription</key><string>$desc</string>"
      IMPORTED_TYPES+="<key>UTTypeConformsTo</key><array>$(printf '<string>%s</string>' ${conforms//,/ })</array>"
      IMPORTED_TYPES+="<key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array>$(printf '<string>%s</string>' ${exts//,/ })</array></dict></dict>" ;;
    *) echo "quicklook-types.txt: unknown line: $verb" >&2; exit 1 ;;
  esac
done < scripts/quicklook-types.txt

# plist <template> <output> [appex ID] [appex executable] [display name] [content types]
plist() {
  sed -e "s#__APP_NAME__#$APP_NAME#g" -e "s#__IMPORTED_TYPES__#$IMPORTED_TYPES#g" -e "s#__APP_ID__#$APP_ID#g" -e "s#__APP_EXE__#$APP_EXE#g" -e "s#__MIN_OS__#$MIN_OS#g" -e "s#__VERSION__#$VERSION#g" -e "s#__BUILD__#$BUILD_NUMBER#g" \
      -e "s#__APPEX_ID__#${3:-}#g" -e "s#__APPEX_EXE__#${4:-}#g" -e "s#__APPEX_DISPLAY__#${5:-}#g" -e "s#__CONTENT_TYPES__#${6:-}#g" \
      -e "s#__WRITER_ID__#${3:-}.writer#g" -e "s#__WRITER_EXE__#$WRITER_EXE#g" "$1" > "$2"
}

WRITER_BIN=$OBJ/$WRITER_EXE
compile "$WRITER_BIN" -module-name "$WRITER_EXE" Writer/main.swift Writer/EditTextView.swift Writer/FileWrite.swift Shared/ArchiveListing.swift Shared/WriterProtocol.swift Shared/LinkPolicy.swift Shared/Settings.swift Shared/Updates.swift
PREVIEW_BIN=$OBJ/$APPEX_EXE
PROBE_FLAGS=()
[ "${PROBE:-0}" = 1 ] && PROBE_FLAGS=(-D PROBE)
# The preview's sources, less its Quick Look entry point: a second host can compile them with its own.
PREVIEW_SRC=(Preview/PreviewController.swift Preview/PDFPane.swift Preview/HTMLPane.swift Preview/MediaPane.swift Preview/QLFallbackPane.swift Preview/RichTextPane.swift Preview/ImagePane.swift Preview/DiskImage.swift Preview/Thumbnail.swift Preview/SettingsStore.swift
  Shared/WriterProtocol.swift Shared/LinkPolicy.swift Shared/Settings.swift Shared/Updates.swift Shared/WebShell.swift Shared/FolderListing.swift Shared/FolderScan.swift)
compile "$PREVIEW_BIN" -application-extension -module-name "$APPEX_EXE" "${PREVIEW_SRC[@]}" Preview/PreviewViewController.swift Preview/Probe.swift \
  ${PROBE_FLAGS[@]+"${PROBE_FLAGS[@]}"} \
  -framework QuickLookUI -framework WebKit -framework PDFKit -framework AVKit -framework AVFoundation -framework QuickLookThumbnailing -Xlinker -e -Xlinker _NSExtensionMain
# The helper sees every key: it is built from its own few files and the settings reader, never the file-parsing code.
HELPER_BIN=$OBJ/$HELPER_EXE
compile "$HELPER_BIN" -module-name "$HELPER_EXE" Helper/*.swift Shared/HelperProtocol.swift Shared/Settings.swift
VIEWER_BIN=$OBJ/$VIEWER_EXE
compile "$VIEWER_BIN" -module-name "$VIEWER_EXE" "${PREVIEW_SRC[@]}" Shared/HelperProtocol.swift Viewer/*.swift \
  -framework QuickLookUI -framework WebKit -framework PDFKit -framework AVKit -framework AVFoundation -framework QuickLookThumbnailing
compile "$APP/Contents/MacOS/$APP_EXE" -parse-as-library -module-name "$APP_EXE" App/*.swift Shared/HelperProtocol.swift Shared/Settings.swift Shared/Updates.swift Shared/WebShell.swift Shared/FolderListing.swift Shared/FolderScan.swift Shared/QuickLookClaims.swift Shared/LinkPolicy.swift \
  -framework WebKit -framework SwiftUI
plist App/Info.plist "$APP/Contents/Info.plist"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
# The writer runs this copy for the one-click update, so it is sealed by the app's signature.
cp scripts/install.sh "$APP/Contents/Resources/install.sh"
cp scripts/uninstall.sh "$APP/Contents/Resources/uninstall.sh"
# What the preview extension claims, by kind: the settings window and install.sh name the other extensions that claim the same.
cp scripts/quicklook-types.txt "$APP/Contents/Resources/quicklook-types.txt"
if [ -f App/AppIcon.icns ]; then cp App/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

ENT=$OUT/Preview.entitlements
{
  echo '<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>'
  echo '<key>com.apple.security.app-sandbox</key><true/>'
  echo '<key>com.apple.security.files.user-selected.read-only</key><true/>'
  # WebKit's WebContent/Networking helpers crash-loop inside a sandboxed appex without this; only remote images are fetched.
  [ "${NET:-1}" = 1 ] && echo '<key>com.apple.security.network.client</key><true/>'
  if [ "$READ_ACCESS" = abs-ro ]; then
    echo '<key>com.apple.security.temporary-exception.files.absolute-path.read-only</key><array><string>/</string></array>'
  fi
  if [ "$READ_ACCESS" = abs-rw ]; then
    echo '<key>com.apple.security.temporary-exception.files.absolute-path.read-write</key><array><string>/</string></array>'
  fi
  # Apple's own previews of Office, iWork, font and 3D files (Preview/QLFallbackPane.swift) are made by Quick Look's daemons; the
  # sandbox reaches them only by these two names. Both extensions: a folder preview shows the same pane. SECURITY.md has why.
  echo '<key>com.apple.security.temporary-exception.mach-lookup.global-name</key><array><string>com.apple.quicklook</string><string>com.apple.quicklook.ThumbnailsAgent</string></array>'
  echo '</dict></plist>'
} > "$ENT"

# appex <bundle ID> <executable> <display name> <content types>: the one preview binary under the given name and ID, with its
# own writer. The controller tells the two apart by bundle ID.
appex() {
  local dir=$APP/Contents/PlugIns/$2.appex
  local xpc=$dir/Contents/XPCServices/$1.writer.xpc
  mkdir -p "$dir/Contents/MacOS" "$dir/Contents/Resources" "$xpc/Contents/MacOS"
  cp "$PREVIEW_BIN" "$dir/Contents/MacOS/$2"
  cp "$WRITER_BIN" "$xpc/Contents/MacOS/$WRITER_EXE"
  cp -R Preview/web "$dir/Contents/Resources/web"
  cp LICENSE THIRD_PARTY_NOTICES.md scripts/quicklook-types.txt "$dir/Contents/Resources/"
  plist Preview/Info.plist "$dir/Contents/Info.plist" "$1" "$2" "$3" "$4"
  plist Writer/Info.plist "$xpc/Contents/Info.plist" "$1" "$2" "$3" "$4"
  codesign "${SIGN_ARGS[@]}" "$xpc"
  codesign "${SIGN_ARGS[@]}" --entitlements "$ENT" "$dir"
}
types() { printf '<string>%s</string>' "$@"; }
appex "$APPEX_ID" "$APPEX_EXE" "$APP_NAME" "$(types "${CLAIMS[@]}" "$ROUTE_TYPE")"
appex "$FOLDERS_ID" "$FOLDERS_EXE" "$APP_NAME Folders" "$(types public.folder public.directory)"

# The viewer: the preview extension's entitlements, plus the one Mach name that reaches the helper.
VIEWER_ENT=$OUT/Viewer.entitlements
sed 's#<string>com.apple.quicklook.ThumbnailsAgent</string></array>#<string>com.apple.quicklook.ThumbnailsAgent</string><string>'"$HELPER_ID"'</string></array>#' "$ENT" > "$VIEWER_ENT"
grep -q "<string>$HELPER_ID</string>" "$VIEWER_ENT" || { echo "viewer entitlements: helper Mach name not added" >&2; exit 1; }
VIEWER_DIR="$APP/Contents/Helpers/$APP_NAME Viewer.app"
VIEWER_XPC=$VIEWER_DIR/Contents/XPCServices/$VIEWER_ID.writer.xpc
mkdir -p "$VIEWER_DIR/Contents/MacOS" "$VIEWER_DIR/Contents/Resources" "$VIEWER_XPC/Contents/MacOS"
cp "$VIEWER_BIN" "$VIEWER_DIR/Contents/MacOS/$VIEWER_EXE"
cp "$WRITER_BIN" "$VIEWER_XPC/Contents/MacOS/$WRITER_EXE"
cp -R Preview/web "$VIEWER_DIR/Contents/Resources/web"
# What spacebar claims: Apple's previews in the panel are never asked for these (FileTypes.appleQuickLookType).
cp LICENSE THIRD_PARTY_NOTICES.md scripts/quicklook-types.txt "$VIEWER_DIR/Contents/Resources/"
plist Viewer/Info.plist "$VIEWER_DIR/Contents/Info.plist" "$VIEWER_ID" "$VIEWER_EXE" "$APP_NAME"
plist Writer/Info.plist "$VIEWER_XPC/Contents/Info.plist" "$VIEWER_ID"
# Under the hardened runtime, like the helper: the helper admits only peers that are, so no library can be injected into a
# process it trusts.
codesign "${SIGN_ARGS[@]}" --options runtime "$VIEWER_XPC"
codesign "${SIGN_ARGS[@]}" --options runtime --entitlements "$VIEWER_ENT" "$VIEWER_DIR"

# The helper: unsandboxed and without entitlements, under the hardened runtime. launchd starts it from the app's agent plist.
HELPER_DIR="$APP/Contents/Helpers/$APP_NAME Helper.app"
mkdir -p "$HELPER_DIR/Contents/MacOS" "$APP/Contents/Library/LaunchAgents"
cp "$HELPER_BIN" "$HELPER_DIR/Contents/MacOS/$HELPER_EXE"
plist Helper/Info.plist "$HELPER_DIR/Contents/Info.plist" "$HELPER_ID" "$HELPER_EXE" "$APP_NAME"
sed -e "s#__HELPER_ID__#$HELPER_ID#g" -e "s#__HELPER_PROGRAM__#Contents/Helpers/$APP_NAME Helper.app/Contents/MacOS/$HELPER_EXE#g" -e "s#__APP_ID__#$APP_ID#g" \
  Helper/agent.plist > "$APP/Contents/Library/LaunchAgents/$HELPER_ID.plist"
codesign "${SIGN_ARGS[@]}" --options runtime "$HELPER_DIR"
codesign "${SIGN_ARGS[@]}" --options runtime "$APP"
rm -rf "$OBJ"
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/$APP_EXE"), macOS $MIN_OS+)"
[ "${NO_INSTALL:-0}" = 1 ] && exit 0

mkdir -p "$INSTALL_DIR"
DEST="$INSTALL_DIR/$APP_NAME.app"
for ex in "$APPEX_EXE" "$FOLDERS_EXE"; do pluginkit -r "$DEST/Contents/PlugIns/$ex.appex" 2>/dev/null || true; done
rm -rf "$DEST"
cp -R "$APP" "$DEST"
"$LSREGISTER" -f -R "$DEST"
pluginkit -a "$DEST/Contents/PlugIns/$APPEX_EXE.appex"
pluginkit -a "$DEST/Contents/PlugIns/$FOLDERS_EXE.appex"
# Folder previews are on unless settings.json turns folderMode off. A file from before version 2 stores the old default
# (false) and reads as on until the app or a writer migrates it. The app keeps the extension in step when the setting changes.
# The support folder keeps its legacy name (spacebar.md) until the app or a writer first runs and moves it.
SETTINGS="$HOME/Library/Application Support/$APP_NAME/settings.json"
[ -e "$(dirname "$SETTINGS")" ] || SETTINGS="$HOME/Library/Application Support/spacebar.md/settings.json"
if grep -qE '"folderMode"[[:space:]]*:[[:space:]]*false' "$SETTINGS" 2>/dev/null && grep -qE '"version"[[:space:]]*:[[:space:]]*([2-9]|[1-9][0-9])' "$SETTINGS"; then
  pluginkit -e ignore -i "$FOLDERS_ID"
else
  pluginkit -e use -i "$FOLDERS_ID"
fi
# A running extension keeps serving its old code until it exits. It is not killed: it may be mid-write for an open preview.
running=$(pgrep -x "$APPEX_EXE" || true)
[ -n "$running" ] && echo "note: $APPEX_EXE still running (pid $running); close its Quick Look preview to load this build"
qlmanage -r >/dev/null 2>&1
qlmanage -r cache >/dev/null 2>&1
# As install.sh after its swap: the viewer running the replaced code quits, its writer first (the helper starts the new one),
# and a registered helper is registered again in the background, since launchd refuses a replaced helper until then.
viewer=$(printf '^%s/' "$DEST/Contents/Helpers/$APP_NAME Viewer.app" | sed 's/[][\.*$+?(){}|]/\\&/g')
pkill -f "${viewer}Contents/XPCServices/" || true
for _ in $(seq 30); do pgrep -f "${viewer}Contents/XPCServices/" >/dev/null || break; sleep 0.2; done
pkill -f "$viewer" || true
if launchctl print "gui/$(id -u)/$HELPER_ID" >/dev/null 2>&1; then
  helper_log="$HOME/Library/Logs/spacebar-helper.log"
  mkdir -p "$(dirname "$helper_log")"
  printf '=== %s reregister after build.sh ===\n' "$(date '+%Y-%m-%d %H:%M:%S')" >>"$helper_log"
  nohup "$DEST/Contents/MacOS/$APP_EXE" --reregister >>"$helper_log" 2>&1 </dev/null &
  echo "registering the Space helper again in the background (log: $helper_log)"
fi
echo "installed $DEST (READ_ACCESS=$READ_ACCESS PROBE=${PROBE:-0} SIGN_ID=$SIGN_ID)"
pluginkit -mAvvv -i "$APPEX_ID" | sed -n '1,4p'
pluginkit -m -i "$FOLDERS_ID"
