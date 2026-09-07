# Xbox Voice Deck

A native Swift/SwiftUI macOS wired audio bridge for the HyperX Cloud III boom microphone and an Xbox Series S controller. All audio processing is local. No AI voice models, accounts, paid APIs, subscriptions, network audio, Remote Play, Electron, hosted services or bundled drivers.

**Phase 2 software implemented; physical calibration pending. The physical Mac/HyperX/USB/Xbox routing gate is still open.** No soundboard, voice presets or advanced effects are included. Do not advance to them until the routing gate passes.

## Implemented

* A native Xcode app and hostless XCTest target; no package dependencies.
* Core Audio device inventory with ID, channel counts, nominal/supported rates, buffer/range, manufacturer, clock domain, device/stream latency and safety offsets.
* Four explicit endpoint selectors, stable UID selection persistence, mic channel choice and mono/stereo Xbox capture. No default-device fallback.
* Independent **Test input** / **Test output** buttons beside all four selectors. Inputs show live meters for up to ten seconds without playback; outputs require confirmation and play a fixed quiet two-second tone. See [endpoint tests](docs/ENDPOINT_TESTS.md).
* Two independent routes using four Apple AUHAL units. Each route has a preallocated C11 SPSC ring, windowed-sinc adaptive sample-rate converter, gain/mute, meters and buffer counters. Swift owns device/control/UI work; audio callbacks stay entirely in C.
* 44.1 and 48 kHz device formats; Float32 internally, with one adaptive conversion per direction. 48 kHz is preferred but hardware rates are never changed silently.
* Requested buffer sizes 32/64/128/256/512 frames, with range/readback checks and a “Keep hardware” option. 128 is the initial candidate; the lowest stable size requires hardware testing. Changes can affect other apps using that device.
* Both outputs start muted. Xbox gain starts at −60 dB, capped at −30 dB; an instant-attack/100 ms-release limiter and independent hard ceiling stay active. Headphone gain starts at −20 dB. Gain changes ramp.
* Actual raw mic, Xbox input (including L/R), Xbox output and headphone output meters with held peaks/clip counts, queue fill, drift correction, underrun/overrun/drop/resync counters.
* Bypass restores normal unity microphone input gain and preserves safe output gain. It cancels any calibration tone and latches Xbox mute; otherwise existing mutes are preserved. Cmd-Shift-B is **app-local**, not a global hotkey.
* Dedicated calibration screen with 1 dB steps, limiter telemetry, confirmed two-second tone, reviewed device-specific profiles and a silent hardware-free safety check. See [CALIBRATION.md](docs/CALIBRATION.md).
* Guided Preflight with endpoint/buffer/permission checks, a staged physical checklist and timestamped local JSON readiness reports. See [READINESS.md](docs/READINESS.md).
* Visible startup/callback errors, microphone permission handling, device/jack/rate/buffer invalidation with safe stop and explicit restart, copied diagnostics and local OSLog events. No microphone recordings.

Read [Audio architecture](docs/AUDIO_ARCHITECTURE.md) for the decision made before implementation, alternatives, callback ownership, synchronization, drift strategy and limitations. Apple's [AUHAL technical note](https://developer.apple.com/library/archive/technotes/tn2091/_index.html) is the principal API reference.

## Requirements and build

* macOS **14.0 or later**, Apple Silicon. Deployment target is macOS 14; this pass was built and run on a newer M5 Pro development Mac. M1 runtime validation remains outstanding.
* Xcode **16 or later** with the macOS SDK; this pass uses installed Xcode 27.0. Older supported-target runtime/compiler combinations are not yet tested. ARM64 is the configured architecture.
* Hardware listed in [HARDWARE_SETUP.md](docs/HARDWARE_SETUP.md).

Clone on your M1 (or another Apple Silicon Mac), open **XboxVoiceDeck.xcodeproj**, select the **XboxVoiceDeck** scheme and **My Mac**, and press Run. Local builds use ad-hoc signing; no developer account is needed. For a distribution build, configure your own signing/notarization separately. This repository distributes source; no notarized app release is provided yet.

```sh
git clone https://github.com/CyberJorsh/XboxVoiceDeck.git
cd XboxVoiceDeck
open XboxVoiceDeck.xcodeproj
# Or build directly from Terminal:
bash scripts/build.sh
open build/DerivedData/Build/Products/Debug/XboxVoiceDeck.app
```

For an optimized build, run `bash scripts/build.sh Release`. The scripts honor `DEVELOPER_DIR`, then your selected full Xcode installation, with `/Applications/Xcode.app` as a fallback. Override it when needed, for example `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer bash scripts/build.sh`.

The project is checked in as plain Xcode project files; `python3 scripts/generate_project.py` regenerates them after adding source files. XcodeGen and Swift Package Manager are unnecessary. The Python generator is development tooling only; the app does not require Python. There are no submodules, secret configuration files or external packages needed to clone and build.

## Hardware wiring and first run

```
HyperX TRRS → Mac headset jack
Controller TRRS → CTIA headset splitter
Splitter headphone branch → suitable level matching → USB input
USB output → suitable headset-mic interface / attenuation → splitter mic branch
USB adapter → Mac USB-C
```

**The Xbox controller expects headset microphone-level audio. Depending on the USB audio adapter, an inline attenuator may be required. Software volume reduction does not guarantee electrical compatibility.** The controller headphone output can also overload a USB **mic** input. Read the full [wiring, CTIA pinout, mono/stereo and level guidance](docs/HARDWARE_SETUP.md) before connecting the output path.

Select all four endpoints and actual input channels. A device labelled “MacBook microphone” is not proof that the HyperX boom mic is selected. The Preflight tab checks software configuration and guides physical observations. Start muted, verify the two input meters independently, unmute headphones cautiously, then check outgoing microphone levels starting at −60 dB. The Calibration tab provides a confirmed low-level tone and reviewed profile restoration. Without devices, use the silent software safety check or `bash scripts/readiness_check.sh` for a Release build and preparation checks.

Click **Allow microphone access** in Routing or Preflight before configuring devices. This requests macOS permission without opening audio streams or starting routing. Start muted also requests access if needed after validating the selected devices. If denied, use **System Settings → Privacy & Security → Microphone → Xbox Voice Deck**, then return to the app; **Refresh permission** checks again immediately. The app does not repeatedly prompt after denial. Both capture inputs need permission. Rebuilding with a changed signing identity can require macOS permission approval again. See [microphone permission troubleshooting](docs/MICROPHONE_PERMISSION.md) if the app is missing from Settings.

## Tests and diagnostics

```sh
bash scripts/test.sh
bash scripts/ui_test.sh       # Native controls with clearly labelled simulated services
bash scripts/safety_check.sh   # Silent: no audio devices opened
bash scripts/device_probe.sh
# Optional: zero-sample output-component test, with an explicitly enumerated ID:
bash scripts/device_probe.sh --silent-output 71
```

Device IDs are volatile; **replace 71 with the current output ID**, do not reuse it blindly. The silent probe creates and starts one AUHAL output, checks 200 callbacks, and never captures a microphone or plays an audible signal. It does not validate input capture, physical cabling or Xbox reception.

`scripts/test.sh` runs XCTest including the actual app-model lifecycle and preflight/report logic, ten healthy clock/rate/buffer schedules, two deliberate fault/recovery schedules, concurrent ring stress, and Address/UndefinedBehavior/Thread sanitizer stress. See [CLOCK_TESTS.md](docs/CLOCK_TESTS.md) for durations and thresholds. `scripts/ui_test.sh` exercises native controls through Debug-only fixtures; these tests open no audio devices. Soundboard, voice-preset and global-hotkey tests belong to their implementation phases.

The [four-endpoint probe](docs/ROUTING_PROBE.md) validates an explicit configuration and can run a bounded, muted session through the actual engine when enough devices and capture permission are available. It exports counters rather than audio and never substitutes a default device.

Test results are generated under `build/tests/`. Local `build/` and `artifacts/` directories are intentionally excluded from Git; machine logs and device snapshots are not published. See [VALIDATION.md](docs/VALIDATION.md) for the recorded first-pass results and outstanding gates. **Copy diagnostics** includes device/runtime statistics but no recorded microphone content, machine serial number or hardware UUID. OSLog events can be read with:

```sh
log show --last 10m --predicate 'subsystem == "com.justjorshin.XboxVoiceDeck"'
```

Settings are local UserDefaults for `com.justjorshin.XboxVoiceDeck`; endpoint/channel/buffer selections and explicitly saved calibration profiles are stored locally. Profiles never automatically restore levels or unmute outputs. Output gains and mutes reset safely on launch/start. No database is used. Do not enable logging inside the realtime callbacks.

## Troubleshooting and limitations

| Symptom | Check |
| --- | --- |
| Only built-in microphone/speakers listed | Connect headset and USB interface, Refresh, inspect Audio MIDI Setup. The app will not fabricate missing endpoints. |
| No HyperX boom mic | Verify selected physical data source with the headset mute switch. Some adapter/jack configurations need additional input hardware. |
| Mono adapter rejected in Stereo mode | Turn Stereo off. A microphone input is often mono; a cable cannot create stereo capture. |
| No Xbox mic recognition even with activity on Mac | Check CTIA splitter orientation, required mic load/bias handling and level-matching hardware before increasing gain. Mac meters do not prove the controller receives audio. |
| Xbox input distorted at low app gain | Lower controller headphone level; ADC clipping occurs before software. Check whether the USB input is mic-level rather than line-level. |
| Unsupported format | Select 44.1 or 48 kHz in Audio MIDI Setup. 88.2/96 kHz are reported but unsupported in Phase 1. |
| Buffer request rejected | Use “Keep hardware” or a supported size. Inspect readback/error; hardware buffer size is shared with other apps. |
| Disconnect or format-change status | Both paths stop. Reconnect, verify saved UID selectors and restart explicitly. No automatic audio restart in Phase 1. |
| Underruns, overruns, audible warble | Increase buffer size; check USB stability/CPU load. Drift controller compensates up to ±2,000 ppm; repeated resync is a problem, not successful stable routing. |
| Voice/game feedback | Stop and inspect analog wiring and controller audio settings. Software has no incoming-to-outgoing connection, but cannot prevent externally introduced loops. |
| Output meter barely moves | Xbox output is intentionally extremely low. Read dBFS; do not increase blindly. |

Estimated software latency is a conservative budget, not a measured delay. Default 128-frame operation is designed around a sub-20 ms software goal; 512 frames may exceed it. Hardware ADC/DAC, safety buffers and the Xbox add latency. ASRC quality and long-term stability still require listening and physical loopback tests on the intended M1/USB devices. The 32-tap interpolator favors low latency; its quality near Nyquist is not a mastering-quality guarantee. Stop/mute and discontinuity recovery can create an abrupt transition; normal gain changes and re-prime fade-ins are smoothed.

Built-in and USB mono/stereo endpoints at supported rates are the primary intended devices; up to 32 channels can be opened, with explicit input-channel selection and output on channels 1/2 (remaining outputs silent). Phase 1 does not unpack arbitrary aggregate subdevice selections or guarantee all third-party driver behavior. Device rates/buffers are inspected at start; future automatic reconnect must remain fail-closed. Unsupported or inaccessible devices cause a visible error.

## Optional BlackHole

BlackHole is **not required or bundled**. If already installed, it appears through ordinary Core Audio enumeration and can be explicitly selected like any other device. No BlackHole device was present during this pass. For optional installation follow the project's [official instructions](https://github.com/ExistentialAudio/BlackHole); install it yourself only if needed for future Mac-app routing or isolated testing. Do not select virtual feedback routes without understanding their external connections. The primary architecture remains the physical wired bridge.

## Next phases

1. **Finish the Phase 1 physical acceptance gate** in [HARDWARE_SETUP.md](docs/HARDWARE_SETUP.md): verify real boom mic capture, both simultaneous directions, no game audio into outgoing mic, sustained stability, unplug/reconnect and measured latency on the M1/Xbox setup.
2. Complete physical Phase 2 calibration using the implemented [calibration workflow](docs/CALIBRATION.md), and resolve any limiter, electrical-interface or audible behavior issues found with the actual adapter.
3. Phase 3: live traditional-DSP Normal/Deep/High/Radio/Robot, only after the route gate passes.
4. Later: local soundboard mixed after mic DSP, Demon/Echo/custom JSON presets, global hotkeys, monitoring, fuller persistence, setup wizard and automatic safe reconnection.

This pass does not create fake controls for those future features and does not claim the hardware gate has passed.

## Public development

The [macOS CI workflow](.github/workflows/macos.yml) builds Release and runs the automated suite on a GitHub-hosted ARM64 macOS runner for pushes to `main` and pull requests. It checks project regeneration and retains generated test reports for seven days. CI does not access physical Xbox hardware or microphone audio. This development workflow is separate from the app, which has no cloud runtime dependency.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and reporting guidance. Licensed under [MIT](LICENSE). Xbox Voice Deck is an independent project and is not affiliated with or endorsed by Microsoft or HyperX.
