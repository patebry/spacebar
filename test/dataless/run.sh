#!/bin/bash
# Reads files iCloud has evicted (dataless) the way the extension does, sandboxed like it and with Quick Look's no-materialization
# policy: the Markdown read, FileView's text read, PDFPane, and off the main thread FileLoader and the file host's image read
# (with a main-thread heartbeat), plus FileLoader's cancellation and timeout with injected readers. Downloads the files it reads.
#   test/dataless/run.sh [DIR [MD CSV PDF [LOADMD IMAGE]]]   default ~/Desktop/spacebar-film with docs/faq.md, budget.csv,
#                        invoice-0042.pdf, vault-demo/Daily/2026-09-25.md, design/wireframe.png
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
id=md.spacebar.test.webcheck
printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>' "$id" > "$out/Info.plist"
cat > "$out/ent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.files.user-selected.read-only</key><true/>
<key>com.apple.security.network.client</key><true/><key>com.apple.security.temporary-exception.files.absolute-path.read-only</key>
<array><string>/</string></array></dict></plist>
PLIST
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/dataless/main.swift Shared/FolderListing.swift Preview/PDFPane.swift Shared/LinkPolicy.swift \
  Shared/WebShell.swift Shared/Settings.swift Shared/FolderScan.swift -framework WebKit \
  ${DATALESS_EXTRA:-} -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$out/Info.plist" -o "$out/dataless"
codesign --force --sign - -i "$id" --entitlements "$out/ent.plist" "$out/dataless" 2>/dev/null
"$out/dataless" "$@"
