#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode_environment.sh
mkdir -p build/tests
# Debug-only fixtures exercise native controls without opening audio hardware.
xcodebuild -project XboxVoiceDeck.xcodeproj -scheme XboxVoiceDeck -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  -only-testing:XboxVoiceDeckUITests \
  -resultBundlePath "build/tests/UI-$(date +%Y%m%d-%H%M%S).xcresult" test
