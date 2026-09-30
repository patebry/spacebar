#!/bin/bash
# Builds and runs the Space panel's own checks: the frame it remembers per display (Viewer/PanelFrame.swift), in memory
# defaults, and what ⌘C puts on the pasteboard (Viewer/FinderCopy.swift), on a private named pasteboard, never the
# clipboard. No window.
set -euo pipefail
cd "$(dirname "$0")/../.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
xcrun swiftc -swift-version 5 -O -target arm64-apple-macos13.0 test/panel/main.swift Viewer/PanelFrame.swift Viewer/FinderCopy.swift -o "$out/panel"
"$out/panel"
