#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/xcode_environment.sh
mkdir -p build/readiness
deck_readiness_log="build/readiness/check-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$deck_readiness_log") 2>&1
echo "Xbox Voice Deck software preparation. No audio device is started; no microphone is captured."
sw_vers
uname -m
xcodebuild -version
bash scripts/build.sh Release
bash scripts/safety_check.sh
bash scripts/routing_probe.sh --self-test
bash scripts/device_probe.sh
echo "Software preparation completed. Physical compatibility, duplex routing and latency remain unverified."
echo "Run bash scripts/test.sh for the full unit/stress suite and bash scripts/ui_test.sh for native UI fixtures."
echo "Log: $deck_readiness_log"
