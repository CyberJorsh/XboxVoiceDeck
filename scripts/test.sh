#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode_environment.sh
mkdir -p build/tests artifacts
xcodebuild -project XboxVoiceDeck.xcodeproj -scheme XboxVoiceDeck -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -skip-testing:XboxVoiceDeckUITests \
  -resultBundlePath "build/tests/Tests-$(date +%Y%m%d-%H%M%S).xcresult" test
xcrun clang -O2 -g -std=gnu11 -Wall -Wextra -Werror -I XboxVoiceDeck/Audio/Realtime \
  XboxVoiceDeck/Audio/Realtime/DeckAudio.c tests/ClockSimulation.c \
  -framework AudioToolbox -framework CoreAudio -o build/tests/clock-simulation
build/tests/clock-simulation
xcrun clang -O1 -g -std=gnu11 -fsanitize=address,undefined -I XboxVoiceDeck/Audio/Realtime \
  XboxVoiceDeck/Audio/Realtime/DeckAudio.c tests/ClockSimulation.c \
  -framework AudioToolbox -framework CoreAudio -o build/tests/clock-asan
build/tests/clock-asan --threads-only
xcrun clang -O1 -g -std=gnu11 -fsanitize=thread -I XboxVoiceDeck/Audio/Realtime \
  XboxVoiceDeck/Audio/Realtime/DeckAudio.c tests/ClockSimulation.c \
  -framework AudioToolbox -framework CoreAudio -o build/tests/clock-tsan
build/tests/clock-tsan --threads-only
