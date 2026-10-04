#!/bin/bash
# Checks install.sh's list of other Quick Look extensions (rival_report) on made-up extensions and pluginkit output: only
# install.sh's two read-only functions are taken out and run, never the script; no pluginkit, no qlmanage, nothing registered.
set -euo pipefail
cd "$(dirname "$0")/../.."
sh -n scripts/install.sh
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fns=$(sed -n '/^rival_report() {/,/^}/p; /^ql_types() {/,/^}/p' scripts/install.sh)
[ -n "$fns" ] || { echo "FAIL rival_report or ql_types not found in install.sh"; exit 1; }

# A spacebar.app with its claims, as build.sh makes it.
app="$t/spacebar.app"
mkdir -p "$app/Contents/Resources" "$app/Contents/PlugIns/SpacebarPreview.appex/Contents"
cp scripts/quicklook-types.txt "$app/Contents/Resources/"
plist() { # plist <appex> <type>...
  local dir=$1; shift
  mkdir -p "$dir/Contents"
  python3 - "$dir/Contents/Info.plist" "$@" <<'PY'
import plistlib, sys
plistlib.dump({'NSExtension': {'NSExtensionAttributes': {'QLSupportedContentTypes': sys.argv[2:]}}}, open(sys.argv[1], 'wb'))
PY
}
ours=$(awk '$1 == "claim" { print $2 } $1 == "declare" { split($2, e, ","); print "md.spacebar.type." e[1] }' scripts/quicklook-types.txt)
# shellcheck disable=SC2086
plist "$app/Contents/PlugIns/SpacebarPreview.appex" $ours md.spacebar.qlmanage
plist "$t/Syntax Highlight.appex" public.swift-source public.python-script md.spacebar.type.go com.netscape.javascript-source public.json public.yaml \
  public.plain-text public.source-code public.zip-archive
plist "$t/QLMarkdown.appex" net.daringfireball.markdown public.markdown com.unknown.markdown
plist "$t/Off.appex" net.daringfireball.markdown
plist "$t/Images.appex" public.png public.jpeg
plist "$t/NoTypes.appex"
plist "$t/Apple.appex" public.json public.xml com.apple.property-list
listing="$t/pluginkit.txt"
{
  printf '     com.example.SyntaxHighlight(2.1)\n\t            Path = %s\n\t    Display Name = Syntax Highlight\n\n' "$t/Syntax Highlight.appex"
  printf '+    org.sbarex.QLMarkdown(1.0)\n\t            Path = %s\n\n' "$t/QLMarkdown.appex"
  printf -- '-    com.example.Off(1.0)\n\t            Path = %s\n\n' "$t/Off.appex"
  printf '     com.example.Images(1.0)\n\t            Path = %s\n\n' "$t/Images.appex"
  printf '     com.example.NoTypes(1.0)\n\t            Path = %s\n\n' "$t/NoTypes.appex"
  printf '     com.example.Gone(1.0)\n\t            Path = %s\n\n' "$t/Gone.appex"
  printf '     com.apple.QuickLookUIFramework.QLPreviewGenerationExtension(1.0)\n\t            Path = %s\n\n' "$t/Apple.appex"
  printf '+    md.spacebar.preview(0.3.0)\n\t            Path = %s\n\n' "$app/Contents/PlugIns/SpacebarPreview.appex"
} > "$listing"

out=$(sh -c "$fns"'
rival_report "$1" < "$2"' sh "$app" "$listing")
printf '%s\n' "$out"
fail=0
check() { if eval "$2"; then echo "PASS $1"; else echo "FAIL $1"; fail=1; fi; }
check "Syntax Highlight: code, data and archives counted by group; parent, Apple-only and spacebar's own type IDs not" \
  '[[ $out == *"com.example.SyntaxHighlight  $t/Syntax Highlight.appex"*"also previews code: 3 types, data: 2 types, archives: 1 type"* ]]'
check "QLMarkdown: Markdown, a vendor Markdown type included" '[[ $out == *"org.sbarex.QLMarkdown"*"also previews Markdown: 3 types"* ]]'
check "an extension that is off is not listed" '[[ $out != *com.example.Off* ]]'
check "no overlap, no types, or no bundle: not listed" '[[ $out != *Images* && $out != *NoTypes* && $out != *Gone* ]]'
check "spacebar itself and Apple's own previewers are not listed" '[[ $out != *md.spacebar.preview* && $out != *com.apple.* ]]'
check "exactly two extensions listed" '[ "$(printf "%s\n" "$out" | grep -c "also previews")" = 2 ]'
# Without the grouped list (an older app), the counts still come, ungrouped.
rm "$app/Contents/Resources/quicklook-types.txt"
out=$(sh -c "$fns"'
rival_report "$1" < "$2"' sh "$app" "$listing")
check "without quicklook-types.txt: counted as other types, Markdown still named" \
  '[[ $out == *"also previews other types: 6 types"* && $out == *"also previews Markdown: 3 types"* ]]'
[ "$fail" = 0 ] && echo "rivals: all passed" || { echo "rivals: failed"; exit 1; }
