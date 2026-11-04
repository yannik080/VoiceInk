#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

out="$PWD/.review-build/EnhancementRetryPolicyCheck"
mkdir -p "$(dirname "$out")"
swiftc -swift-version 5 -parse-as-library \
    VoiceInk/Core/Enhancement/EnhancementRetryPolicy.swift \
    VoiceInk/Core/Enhancement/EnhancementFallbackRoute.swift \
    Tests/EnhancementRetryPolicyCheck.swift \
    -o "$out"
"$out"
