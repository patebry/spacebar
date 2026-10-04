#!/bin/bash
# Runs the position and scroll checks (test/jank/main.py) in the offscreen page harness.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 test/jank/main.py
