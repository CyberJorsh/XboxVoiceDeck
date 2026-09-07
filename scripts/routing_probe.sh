#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode_environment.sh
mkdir -p build/routing-probe
xcrun clang -O2 -std=gnu11 -mmacosx-version-min=14.0 \
  -c XboxVoiceDeck/Audio/Realtime/DeckAudio.c -o build/routing-probe/DeckAudio.o
xcrun swiftc -O -target arm64-apple-macosx14.0 \
  -import-objc-header XboxVoiceDeck/Support/BridgingHeader.h -I XboxVoiceDeck/Audio/Realtime \
  XboxVoiceDeck/Audio/Devices/AudioDeviceManager.swift XboxVoiceDeck/Audio/CoreAudio/HALUnit.swift \
  XboxVoiceDeck/Models/RoutingConfiguration.swift XboxVoiceDeck/Settings/CalibrationStore.swift \
  XboxVoiceDeck/Audio/Routing/AudioRoutingEngine.swift \
  tools/RoutingProbe/Arguments.swift tools/RoutingProbe/Validation.swift \
  tools/RoutingProbe/ArgumentTests.swift tools/RoutingProbe/main.swift \
  build/routing-probe/DeckAudio.o -framework AudioToolbox -framework CoreAudio -framework AVFoundation \
  -o build/routing-probe/routing-probe
build/routing-probe/routing-probe "$@"
