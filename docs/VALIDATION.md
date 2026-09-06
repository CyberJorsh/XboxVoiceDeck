# Phase 0/1 validation report

The original report below is retained as the Phase 1 baseline. See [Phase 2 software validation](#phase-2-software-validation) for the subsequent safety implementation.

Date: 2026-09-05. This report records the initial local validation before public repository publication. The repository includes source, the Xcode project and reproducible build/test scripts. Raw local logs, device snapshots, result bundles and compiled apps are excluded from Git; artifact paths below identify evidence retained on the original development host. Run the scripts to generate results on another Mac.

## Implemented architecture and scope

Four explicitly bound AUHAL units, two independent fixed-capacity SPSC rings, and one adaptive 32-tap / 512-phase windowed-sinc converter per direction. The chosen structure exposes device selection and independent clock behavior without a virtual driver, aggregate device, network service or arbitrary AVAudioEngine device routing assumption. Swift/SwiftUI owns the app and control plane; a C11 kernel owns realtime callbacks.

Both directed paths exist in `AudioRoutingEngine.swift` and `DeckAudio.c`; they are not UI placeholders. There is no Xbox-input reference in the outgoing route. Both outputs start muted; Xbox gain defaults to −60 dB and is capped at −30 dB with an independent digital safety ceiling. Bypass resets mic input gain and preserves output mutes/gains. Full calibration, soundboard, effects, global hotkeys, sidetone and setup wizard are intentionally outside this delivery.

## Build evidence

* Xcode 27.0 (27A5218g), ARM64, macOS deployment target 14.0.
* Debug app build: succeeded, no compile errors. `artifacts/build-debug.log` (local only).
* Release app build: succeeded, no compile errors. `artifacts/build-release.log` (local only).
* The only remaining build warning is Xcode's App Intents metadata extraction being skipped because this app has no AppIntents dependency. No App Intents are requested in Phase 1.
* Output: `build/DerivedData/Build/Products/Release/XboxVoiceDeck.app`.

## Automated validation

**18 XCTest cases, 18 passed, 0 failures.** `artifacts/xctest.log` (local only), result bundle `build/tests/Phase1-Final.xcresult`.

Coverage:

* Unsupported format/dimension rejection; source UID resolution across volatile ID changes.
* Missing-device fail-closed behavior; duplicate capture/output rejection; mono/stereo channel validation.
* Configuration JSON round trip and rejection of malformed/incomplete data.
* Muted startup, priming, ring wrap, whole-block overrun dropping, underrun silence/recovery and high-water resync.
* −60 dB gain, maximum Xbox output ceiling under overdrive, immediate mute, safety-preserving bypass, non-finite sample rejection.
* Stereo separation and isolation between independent route objects.
* First-error safety latch, oversized output callback rejection with buffer guard checks, and shared safety silencing output.

**Seven deterministic two-minute audio-clock simulations passed** (14 minutes of simulated audio, not 14 minutes of real hardware playback). `artifacts/clock-simulation.log` (local only).

| Source → destination | Injected drift | Input/output buffer | Final-minute mean correction |
| --- | ---: | ---: | ---: |
| 48 → 48 kHz | 0 ppm | 128 / 128 | 0.00 ppm |
| 48 → 48 kHz | +500 ppm | 128 / 128 | +499.28 ppm |
| 48 → 48 kHz | −500 ppm | 128 / 128 | −501.15 ppm |
| 44.1 → 48 kHz | +800 ppm | 128 / 256 | +801.20 ppm |
| 48 → 44.1 kHz | −800 ppm | 256 / 128 | −801.21 ppm |
| 44.1 → 44.1 kHz | +1,000 ppm | 32 / 64 | +999.94 ppm |
| 48 → 48 kHz | −1,000 ppm | 512 / 512 | −1,004.71 ppm |

Every case had **zero underruns, overruns and resyncs**, bounded queue fill, no right-channel leakage from the left-only source, and expected 1 kHz tone frequency/amplitude within asserted tolerances. Instantaneous correction includes callback-size jitter; convergence is assessed over the final minute, not a single snapshot. These are simulations, not driver/hardware stability or a latency measurement.

Concurrent producer/consumer stress: 20,000 producer blocks, bounded finite safe-level output. Repeated under AddressSanitizer + UndefinedBehaviorSanitizer and ThreadSanitizer, with **no reported sanitizer failures**. `artifacts/address-sanitizer.log` (local only), `artifacts/thread-sanitizer.log` (local only). Sanitizer runs exercise the kernel; they do not validate proprietary HAL/USB drivers or all Swift UI paths.

## Actual devices and live probe

Observed development host: **Mac17,9, Apple M5 Pro**. This is not the requested M1 machine.

| Enumerated Core Audio device | ID at test time | Input/output | Active rate / buffer |
| --- | ---: | --- | --- |
| MacBook Pro Microphone | 78 | 1 / 0 | 48 kHz / 512 frames |
| MacBook Pro Speakers | 71 | 0 / 2 | 48 kHz / 512 frames |

Both report 44.1/48/88.2/96 kHz hardware capability; the app's current implementation accepts only 44.1/48 kHz. `artifacts/device-inventory.txt` (local only). No HyperX input, USB sound card, controller audio device or BlackHole endpoint was available.

Live output-component probe explicitly bound AUHAL to output **ID 71**, used the current 512-frame hardware buffer, and completed **201 callbacks** with callback error **0**, stop/dispose status **0**, and output peak **0.0**. `artifacts/silent-output-probe.txt` (local only). All output samples were zero. No input unit was created, no microphone was captured, and no audible test tone was played. The probe's callback-count watchdog terminates the test; it does not use sleeps to synchronize audio.

This establishes that the output AUHAL binding, Float32 format, C render callback and clean disposal work on the available speaker device. It **does not establish** two-device duplex capture/playback or Xbox reception.

## Native UI observations

The Release app launched. Native accessibility inspection confirmed the routing screen, four explicit selectors, 128-frame request default, electrical warning and bypass description. The headset-input picker contained the actually enumerated **MacBook Pro Microphone [78]**, with no fabricated headset device. Clicking Start with incomplete selections displayed **“Select all four endpoints explicitly.”** and did not start audio or prompt for microphone access.

Further native automation lost its connection while switching to the meters tab; retry/reset did not restore it. The app process remained running. Full interactive inspection of the meter/diagnostics tabs, clipboard diagnostics, live slider/mute behavior and permission UI remains unverified. The meters and controls are connected in source and their underlying kernel behavior is tested; this is not a claim of completed end-to-end UI acceptance.

## Outstanding physical gates

Follow [HARDWARE_SETUP.md](HARDWARE_SETUP.md) on the intended M1/HyperX/USB/controller equipment:

1. Verify the **actual HyperX boom mic** through the Mac jack, including its physical mute; do not substitute the internal mic.
2. Confirm the USB adapter's real input type, channel count, headphone output level and suitability for controller mic bias/load. Provide proper attenuation/interface hardware if required, in both directions where needed.
3. Verify simultaneous headset→USB and USB→headset operation, intended channel mapping, and no incoming game/chat audio in the outgoing microphone path, including on the Xbox itself.
4. Verify microphone permission grant/denial behavior and visible AudioUnit errors with the actual input hardware.
5. Run at least 30 minutes at the lowest stable buffer; test mixed nominal rates, audible drift, callback stalls, unplug/replug, headset jack removal, source changes and explicit restart.
6. Measure physical end-to-end latency. The sub-20 ms figure remains a target, not a measured result.
7. Verify safe outgoing level using the console. Software gain/clamping cannot certify electrical compatibility or controller microphone detection.

There is no honest substitute for these hardware gates. **Phase 1 physical acceptance is still open.** The next development step is to resolve any failures found there, then implement Phase 2's dedicated calibration/limiter workflow. Do not begin soundboard or voice effects yet.

## Phase 2 software validation

Date: 2026-09-05. App version 0.2.0. The user authorized software-only Phase 2 work while waiting for the physical hardware. **Phase 2 software implemented; physical calibration pending.** No soundboard or voice effects were started.

Implemented: linked-channel sample-peak limiter (instant attack, 100 ms release, zero additional look-ahead frames), independent final output ceiling, bounded confirmed tone, cancellation/deadline/mute safeguards, calibration page, versioned local profiles with explicit review and muted restore, limiter/tone diagnostics, and a silent synthetic check callable from the app or CLI. Exact behavior is documented in [CALIBRATION.md](CALIBRATION.md).

Local evidence (raw artifacts remain ignored):

* **Debug and Release builds passed.** No source compile errors; Xcode's informational App Intents extraction warning remains. Logs: `artifacts/phase2-tests.log`, `artifacts/phase2-build-release.log`.
* **28 XCTest cases passed, zero failures.** Includes the Phase 1 baseline plus limiter overload/attack/release, tone arming guards, two-second sample duration at both supported rates, tone-level caps under later gain edits, completion mute latch, cancellation before render, bypass, underrun/error cancellation, and deadline expiry after deliberately stalled rendering. Profile checks cover persistence, UID-based identity, channel/rate mismatch rejection, mandatory review, invalid levels, corrupt/unknown schema preservation and pending hardware status.
* **Seven two-minute simulated clock runs passed**, with zero underruns/overruns/resyncs and the existing amplitude/frequency/stereo-isolation assertions. These are simulated minutes, not physical playback.
* **ASan/UBSan and TSan stress passed**, now with three concurrent producer, consumer and control threads: 20,000 producer blocks plus 20,000 gain/mute/tone-start/cancel command cycles. No sanitizer reports. These checks concern application memory/state, not a USB driver's internals.
* **The standalone silent diagnostic passed all six checks.** Command: `bash scripts/safety_check.sh`; log: `artifacts/phase2-offline-check.log`. Reported overload output peak was 0.000890 FS at −60 dB output gain; tone stayed at/below its −90 dBFS cap, completed and muted; later level changes did not unmute. The check uses the same kernel and function as the app's button; no Audio Units or audio devices are opened.
* **Native UI inspection was partial.** The new Debug app launched and displayed “Phase 2 software · Physical calibration pending,” the Calibration tab, and the updated bypass help. The native automation connection closed while switching tabs; a screenshot retry also failed. App processes remained running, but the full interactive calibration screen, its confirmation dialog, profile buttons and inactive/sleep cancellation flow could not be accepted through UI automation. Their underlying processing/persistence behavior is exercised in tests; this is not a claim of complete end-to-end GUI validation.

Still unverified: actual M1/HyperX capture and duplex routing; Xbox reception and mic detection; electrical interface/attenuation/loading; audible limiter/mute artifacts; physical tone output; 30-minute real-device stability; physical disconnect/sleep behavior; and measured end-to-end latency. No physical tone or microphone recording was used for this pass. The Phase 1 hardware gate remains open.

### Pre-merge review corrections

Two automated review findings were confirmed in source and corrected before merging: sleep previously skipped a pending permission/start operation, and tone cancellation previously published its inactive state before its separate mute store. Startup now uses an invalidatable request token and permits shutdown during startup. Tone generation, active state and mute now share one atomic word; cancellation publishes inactive and muted together. A command change during a render buffer produces silence until the next callback initializes that command.

Validation after these changes: **30 XCTest cases passed**, including late permission and engine-completion rejection with a subsequent explicit restart. All seven clock simulations and the existing 20,000-cycle concurrent stress passed. An additional **2,000 concurrent cancel/bypass render cycles** asserted that output contained only the bounded tone or silence, never the louder synthetic microphone input; this also passed under ASan/UBSan and TSan. Debug and Release builds, Release signature verification and all six silent checks passed. Local logs: `artifacts/merge-safety-tests.log`, `artifacts/merge-safety-release.log`, `artifacts/merge-safety-offline.log` (ignored).

These regression checks exercise the startup request gate and real C processing kernel. Actual sleep notifications, permission dialogs and audio driver shutdown still require interactive and physical validation.

## Hardware preparation pass (0.3.0)

The preparation pass adds a guided software preflight, a staged physical checklist, local timestamped JSON reports, a four-endpoint muted AUHAL probe, dependency-injected app lifecycle tests, Debug-only native UI fixtures and changing-clock/fault simulations. [READINESS.md](READINESS.md) contains the procedure. Physical acceptance remains pending, including on the reportedly 14-inch target Mac; its exact model and the adapter/splitter specifications remain to be confirmed.

The full-model tests found a real startup crash: the `@Published` mute property observers recursively assigned themselves while stopped or busy. Both now only correct an actual unmute attempt and never forward that rejected command. Tests also found and addressed old snapshots crossing stop/restart and a missing engine session remaining visually connected. Buffer requests are validated consistently before permission/engine startup. The probe distinguishes initial priming trims from unexpected dropped frames so healthy startup is not reported as failure.

Local validation:

* **57 XCTest cases passed:** 30 kernel/configuration/safety cases, 20 actual `DeckModel` lifecycle cases, and seven preflight/report cases. Lifecycle tests inject permission, inventory, engine completions and a monotonic clock; they do not open devices. Log: `artifacts/readiness-verified-tests.log`.
* **Ten healthy clock schedules, two forced-fault recovery schedules and two concurrency scenarios passed.** Approximately 33 simulated minutes, longest single schedule ten minutes. ASan/UBSan and TSan passed; see [CLOCK_TESTS.md](CLOCK_TESTS.md) for precise bounds. Forced faults are deliberately separate from healthy zero-xrun results.
* **Six silent kernel checks and 26 routing-probe argument/configuration/stability checks passed.** The preparation command completed a Release build, these checks and inventory enumeration without opening audio streams. Log: `artifacts/readiness-verified-preparation.log`.
* Debug and Release compiled; Release signature verification passed. The Release executable contains none of the Debug fixture entry point, simulated headset or fixture engine markers. The informational App Intents extraction warning remains.
* **Native UI execution was blocked locally.** All six XCUITest cases compiled, but the runner timed out while enabling automation mode before any UI case executed. Native computer-use inspection of the runner also timed out. This is not a UI pass. Log: `artifacts/readiness-ui.log`.
* The current inventory provides three input/output devices in total but only one output device, so it cannot satisfy the two independent output roles. No four-endpoint capture run or permission prompt was attempted. Probe missing-consent, missing-device and invalid-ID handling were exercised without capture.
* A separate silent output probe on the explicitly selected available speaker device completed **202 callbacks**, realtime error **0**, stop status **0** and output peak **0.0**. It exercised the new AUHAL client-format readback and disposal without opening an input. Log: `artifacts/readiness-silent-auhal.log`. This is one-output evidence, not duplex acceptance.

Raw logs, reports, device identities and result bundles remain local and ignored by Git. None of the above validates Xbox reception, the exact electrical interface, nonzero physical signal isolation, driver stability on the target Mac or measured end-to-end latency.
