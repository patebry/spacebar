#!/bin/bash
# The helper's listener accepts the viewer (and the settings app) signed by its own certificate, and refuses an ad-hoc client
# claiming the viewer's identifier and a client signed by the same certificate under another identifier. The listener runs as
# a temporary launchd job under a test Mach name, removed at the end; the real md.spacebar.helper agent is never touched.
set -euo pipefail
cd "$(dirname "$0")/../.."
SIGN_ID=${SIGN_ID:-$(head -n1 .sign-id 2>/dev/null || true)}
identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
if [ -z "$SIGN_ID" ] || ! grep -qF "$SIGN_ID" <<<"$identities"; then
  SIGN_ID=$(sed -nE 's/^ *[0-9]+\) ([0-9A-F]{40}) ".*"$/\1/p' <<<"$identities" | head -1)
fi
[ -n "$SIGN_ID" ] || { echo "SKIP no code-signing identity: the link cannot be checked"; exit 0; }
out=$(mktemp -d)
label=md.spacebar.helperlinktest.$$
domain=gui/$(id -u)
trap 'launchctl bootout "$domain/$label" 2>/dev/null || true; rm -rf "$out"' EXIT
build() { xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 "$@"; }
build test/helperlink/listener/main.swift Helper/Link.swift Shared/HelperProtocol.swift -o "$out/listener"
build test/helperlink/client/main.swift Shared/HelperProtocol.swift -o "$out/client"
sign() { codesign --force --timestamp=none --sign "$1" --identifier "$2" "$3" 2>/dev/null; }
sign "$SIGN_ID" md.spacebar.helper "$out/listener"
for c in viewer app adhoc other; do cp "$out/client" "$out/client-$c"; done
sign "$SIGN_ID" md.spacebar.viewer "$out/client-viewer"
sign "$SIGN_ID" md.spacebar "$out/client-app"
sign - md.spacebar.viewer "$out/client-adhoc"
sign "$SIGN_ID" md.spacebar.viewer.other "$out/client-other"
cat > "$out/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$out/listener</string><string>$label</string></array>
<key>MachServices</key><dict><key>$label</key><true/></dict>
</dict></plist>
PLIST
launchctl bootstrap "$domain" "$out/$label.plist"
failures=0
expect() {
  local got; got=$("$out/client-$1" "$label")
  if [ "$got" = "$2" ]; then echo "PASS $3"; else echo "FAIL $3 (got: $got)"; failures=$((failures + 1)); fi
}
expect viewer "hello true, status none" "the viewer (same certificate, md.spacebar.viewer) is accepted, as the viewer"
expect app "hello false, status app" "the settings app (same certificate, md.spacebar) is accepted, as the app"
expect adhoc "error 4097" "an ad-hoc client claiming md.spacebar.viewer is refused"
expect other "error 4097" "a client with the same certificate and another identifier is refused"
[ $failures = 0 ] && echo "all helper link checks passed" || { echo "$failures helper link checks failed"; exit 1; }
