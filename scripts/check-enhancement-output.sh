#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="$PWD/.review-build/EnhancementOutputCheck"
mkdir -p "$(dirname "$out")"
swiftc -swift-version 5 -parse-as-library \
    VoiceInk/Core/Enhancement/AIEnhancementOutputFilter.swift \
    Tests/EnhancementOutputCheck.swift -o "$out"
"$out"
