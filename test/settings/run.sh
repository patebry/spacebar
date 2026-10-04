#!/bin/bash
# Builds and runs the settings checks against a temporary support folder (never the real one).
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/settings/main.swift App/SettingsTab.swift Shared/Settings.swift Shared/FolderListing.swift Shared/FolderScan.swift Shared/QuickLookClaims.swift Shared/ArchiveListing.swift Shared/HelperProtocol.swift App/UpdateCheck.swift Shared/Updates.swift -o "$out/settings"
SPACEBAR_SUPPORT_DIR="$out/support" "$out/settings"
