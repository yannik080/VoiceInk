#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

out="$PWD/.review-build/RecordingShortcutResponsivenessCheck"
mkdir -p "$(dirname "$out")"
swiftc -swift-version 5 -parse-as-library \
    VoiceInk/Features/Shortcuts/Coordination/RecordingShortcutModeHandler.swift \
    VoiceInk/Features/Shortcuts/Models/ShortcutAction.swift \
    VoiceInk/Core/Recording/RecordingState.swift \
    Tests/RecordingShortcutResponsivenessCheck.swift \
    -o "$out"
"$out"
