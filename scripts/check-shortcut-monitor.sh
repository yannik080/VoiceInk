#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

out="$PWD/.review-build/ShortcutMonitorCoalescingCheck"
mkdir -p "$(dirname "$out")"
mkdir -p "$out.src"
cp Tests/ShortcutMonitorCoalescingCheck.swift "$out.src/main.swift"
swiftc -swift-version 5 \
    VoiceInk/Features/Shortcuts/Coordination/ShortcutMonitor.swift \
    VoiceInk/Features/Shortcuts/Models/Shortcut.swift \
    VoiceInk/Features/Shortcuts/Models/ShortcutAction.swift \
    VoiceInk/Infrastructure/SystemIntegration/Lifecycle/UserSessionInputPolicy.swift \
    "$out.src/main.swift" \
    -o "$out"
"$out"
