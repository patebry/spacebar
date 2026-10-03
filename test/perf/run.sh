#!/bin/bash
# Runs the main-thread checks (test/perf/main.py) in the offscreen page harness.
set -euo pipefail
cd "$(dirname "$0")/../.."
python3 test/perf/main.py
