#!/bin/bash
# Live media is muted instead of paused: checks LiveMediaDetector against synthetic Now Playing data.
set -euo pipefail
cd "$(dirname "$0")/.."

out="$PWD/.review-build/LiveMediaDetectorCheck"
mkdir -p "$out.src"
cp Tests/LiveMediaDetectorCheck.swift "$out.src/main.swift"
swiftc -swift-version 5 \
    VoiceInk/Infrastructure/SystemIntegration/Media/LiveMediaDetector.swift \
    "$out.src/main.swift" \
    -o "$out"
"$out"
