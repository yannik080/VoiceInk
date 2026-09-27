#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

sparkle="$PWD/.local-build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
if [[ ! -d "$sparkle/Sparkle.framework" ]]; then
    echo 'Resolve the app packages with make local first.' >&2
    exit 1
fi

bundle="$PWD/.review-build/VoiceInkLocalUpdaterCheck.app"
mkdir -p "$bundle/Contents/MacOS"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.voiceink.updater-regression</string>
<key>CFBundleExecutable</key><string>VoiceInkLocalUpdaterCheck</string>
<key>CFBundleName</key><string>VoiceInkLocalUpdaterCheck</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST

# Also check that the upstream distribution configuration still compiles.
swiftc -typecheck -F "$sparkle" VoiceInk/App/Updates/UpdaterViewModel.swift
swiftc -D LOCAL_BUILD -parse-as-library -F "$sparkle" -framework Sparkle \
    -Xlinker -rpath -Xlinker "$sparkle" \
    VoiceInk/App/Updates/UpdaterViewModel.swift Tests/LocalBuildUpdaterCheck.swift \
    -o "$bundle/Contents/MacOS/VoiceInkLocalUpdaterCheck"
"$bundle/Contents/MacOS/VoiceInkLocalUpdaterCheck"
