#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode_environment.sh
mkdir -p build/safety-check
xcrun clang -O2 -std=gnu11 -mmacosx-version-min=14.0 \
  -c XboxVoiceDeck/Audio/Realtime/DeckAudio.c -o build/safety-check/DeckAudio.o
xcrun swiftc -O -target arm64-apple-macosx14.0 \
  -import-objc-header XboxVoiceDeck/Support/BridgingHeader.h -I XboxVoiceDeck/Audio/Realtime \
  XboxVoiceDeck/Audio/Diagnostics/OfflineSafetyCheck.swift tools/SafetyCheck/main.swift \
  build/safety-check/DeckAudio.o -framework AudioToolbox -framework CoreAudio \
  -o build/safety-check/safety-check
build/safety-check/safety-check
