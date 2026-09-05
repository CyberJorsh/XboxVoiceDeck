#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode_environment.sh
deck_configuration="${1:-Debug}"
case "$deck_configuration" in
  Debug|Release) ;;
  *) echo "Usage: bash scripts/build.sh [Debug|Release]" >&2; exit 2 ;;
esac
xcodebuild -project XboxVoiceDeck.xcodeproj -scheme XboxVoiceDeck \
  -configuration "$deck_configuration" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/DerivedData build
