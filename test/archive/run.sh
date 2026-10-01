#!/bin/bash
# Builds and runs the archive listing checks (Shared/ArchiveListing.swift, with FolderListing.swift's ArchiveEntryView): the bsdtar parser on captured output, then real
# archives made in a temp folder.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/archive/main.swift Shared/ArchiveListing.swift Shared/FolderListing.swift -o "$out/archive"
"$out/archive" test/archive/fixtures
