# Contributing

Read [the architecture](docs/AUDIO_ARCHITECTURE.md) and [hardware safety guide](docs/HARDWARE_SETUP.md) first. The current scope is Phase 1 routing plus Phase 2 software safety/calibration. Physical validation on the intended M1, HyperX Cloud III and Xbox setup is still open; keep soundboard and effects work behind that gate.

## Development

1. Clone the repository and open `XboxVoiceDeck.xcodeproj` in Xcode on an Apple Silicon Mac with macOS 14 or later.
2. Use the shared `XboxVoiceDeck` scheme and My Mac destination. No package installation or developer account is required for local ad-hoc builds.
3. Run `bash scripts/build.sh` and `bash scripts/test.sh` before submitting changes.
4. When adding sources, run `python3 scripts/generate_project.py` and commit the regenerated project too.

The scripts honor `DEVELOPER_DIR`; otherwise they use the selected full Xcode installation, then `/Applications/Xcode.app` as a fallback. See the README for the tested compiler and remaining compatibility gates.

## Audio changes

Keep the two directions isolated. Preserve conservative Xbox output gain, clipping protection, muted startup and fail-closed device selection. Never silently switch devices or bypass electrical safety controls. No allocation, locks, logging, disk access or UI work in realtime callbacks. Audio callback contexts must outlive their Audio Units.

Tests should exercise behavior, including failure and recovery paths. Report unit/simulation results separately from physical routing, actual controller reception and measured latency. Hosted CI cannot validate analog wiring or the HyperX boom microphone.

## Reporting issues and pull requests

Include macOS/Xcode versions, adapter model, input/output capabilities, buffer sizes, steps to reproduce and expected/actual behavior. Review copied diagnostics before posting. Do not attach microphone recordings, credentials, personal paths or unreviewed system logs. Use synthetic test signals for reproducible audio bugs.

Describe what changed, why, relevant test results and anything not physically verified. Changes are contributed under this project's [MIT license](LICENSE).
