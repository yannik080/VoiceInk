#!/bin/bash
# Checks that dictation enhancement sends one request per attempt to OpenAI-compatible providers.
set -euo pipefail
cd "$(dirname "$0")/.."

out="$PWD/.review-build/SingleAttemptChatCompletionCheck"
mkdir -p "$out"

# LLMkit at the revision the app is built with. `make local` deletes .local-build, so keep an own copy.
revision=$(python3 -c 'import json,sys; pins=json.load(open(sys.argv[1]))["pins"]; print(next(p["state"]["revision"] for p in pins if p["identity"] == "llmkit"))' \
    VoiceInk.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved)
llmkit="$PWD/.local-build/SourcePackages/checkouts/LLMkit"
if [ "$(git -C "$llmkit" rev-parse HEAD 2>/dev/null)" != "$revision" ]; then
    llmkit="$out/LLMkit"
    if [ "$(git -C "$llmkit" rev-parse HEAD 2>/dev/null)" != "$revision" ]; then
        rm -rf "$llmkit"
        git clone --quiet https://github.com/Beingpax/LLMkit.git "$llmkit"
        git -C "$llmkit" checkout --quiet "$revision"
    fi
fi

find "$llmkit/Sources/LLMkit" -name '*.swift' -print0 | xargs -0 swiftc -swift-version 6 -parse-as-library \
    -emit-library -emit-module -module-name LLMkit \
    -emit-module-path "$out/LLMkit.swiftmodule" -o "$out/libLLMkit.dylib"
swiftc -swift-version 5 -parse-as-library -I "$out" -L "$out" -lLLMkit -Xlinker -rpath -Xlinker "$out" \
    VoiceInk/Infrastructure/Providers/Enhancement/Chat/SingleAttemptChatCompletion.swift \
    Tests/SingleAttemptChatCompletionCheck.swift \
    -o "$out/check"

port_file="$out/port"
rm -f "$port_file"
python3 Tests/ChatCompletionStubServer.py > "$port_file" &
server=$!
trap 'kill $server 2>/dev/null || true' EXIT
for _ in $(seq 50); do [ -s "$port_file" ] && break; sleep 0.1; done

STUB_URL="http://127.0.0.1:$(cat "$port_file")/v1" "$out/check"
