#!/bin/bash
# Builds the settings window with the app's sources and checks its height and scrolling offscreen (the window is never shown).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 -module-name spacebar test/settingswindow/main.swift \
  $(ls App/*.swift | grep -v '^App/main.swift$') Shared/HelperProtocol.swift Shared/Settings.swift Shared/Updates.swift \
  Shared/WebShell.swift Shared/FolderListing.swift Shared/FolderScan.swift Shared/QuickLookClaims.swift Shared/LinkPolicy.swift \
  Shared/SecureInput.swift Shared/DefaultApps.swift -framework WebKit -framework SwiftUI -o "$out/settingswindow"
SPACEBAR_SUPPORT_DIR="$out/support" "$out/settingswindow"
