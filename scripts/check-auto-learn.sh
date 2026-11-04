#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

out="$PWD/.review-build/AutoLearnSnapshotCheck"
mkdir -p "$(dirname "$out")"
swiftc -swift-version 5 -parse-as-library \
    VoiceInk/Features/Dictionary/AutoLearn/AutoLearnTypes.swift \
    VoiceInk/Features/Dictionary/AutoLearn/FinalSnapshotDiffEngine.swift \
    VoiceInk/Features/Dictionary/AutoLearn/CorrectionDiffEngine.swift \
    Tests/AutoLearnSnapshotCheck.swift \
    -o "$out"
"$out"
