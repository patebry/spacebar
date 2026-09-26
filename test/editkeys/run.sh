#!/bin/bash
# Builds and runs the edit text view's Command-shortcut checks: in-process, in a panel that is never shown.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/editkeys/main.swift Writer/EditTextView.swift Shared/WriterProtocol.swift -o "$out/editkeys"
"$out/editkeys"
