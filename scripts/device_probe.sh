#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/probe
source scripts/xcode_environment.sh
xcrun clang -O2 -std=gnu11 -mmacosx-version-min=14.0 -c XboxVoiceDeck/Audio/Realtime/DeckAudio.c -o build/probe/DeckAudio.o
xcrun swiftc -O -target arm64-apple-macosx14.0 \
  -import-objc-header XboxVoiceDeck/Support/BridgingHeader.h -I XboxVoiceDeck/Audio/Realtime \
  XboxVoiceDeck/Audio/Devices/BufferChange.swift XboxVoiceDeck/Audio/Devices/AudioDeviceManager.swift XboxVoiceDeck/Audio/CoreAudio/HALUnit.swift \
  tools/DeviceProbe/main.swift build/probe/DeckAudio.o -framework AudioToolbox -framework CoreAudio \
  -o build/probe/device-probe
build/probe/device-probe "$@"
