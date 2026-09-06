# Four-endpoint routing probe

This developer tool exercises the app's actual `AudioRoutingEngine`, four AUHAL units, ring buffers and asynchronous resamplers. It opens two explicit inputs and two explicit outputs simultaneously, **with both outputs muted throughout**. It does not play a tone, request permission, alter saved app settings, or record input samples. A run lasts 2–60 seconds and exports a local JSON report.

A passing run establishes callback progress and digital silence for that configuration and duration. It does **not** prove audible microphone routing, stereo wiring, electrical compatibility, Xbox reception, real-world latency, or which physical microphone produced input. Use [hardware setup](HARDWARE_SETUP.md) and [calibration](CALIBRATION.md) for those separate checks. No completed physical four-endpoint run is claimed by this document.

## Build and inspect without capturing

Requirements match the app: Apple Silicon, macOS 14 or later, and Xcode. Commands run from the repository root. Build products stay in ignored `build/` and reports default to ignored `artifacts/`.

```bash
bash scripts/device_probe.sh --json
bash scripts/routing_probe.sh --help
bash scripts/routing_probe.sh --self-test
```

The device inventory includes stable UIDs, current IDs, input/output channel counts, current rate, supported rates and buffer frames. No microphone is opened for these commands. The self-test exercises argument parsing, configuration constraints and stability-counter decisions using synthetic data. A successful self-test is not a hardware test.

The older single-output probe also remains available:

```bash
bash scripts/device_probe.sh --silent-output CORE_AUDIO_ID
```

It requires a supported explicit output ID, emits digital zero and verifies callbacks and cleanup. It does not test either capture path. Missing devices, unsupported rates/channels/buffers, allocation failures and HAL errors fail visibly. IDs may change after reconnecting, so inventory them again first.

## Explicit configuration

The app's Preflight screen can export a readiness report. Pass that JSON file directly to `--config`; the probe reads its `configuration` field and requires `schemaVersion: 1`. It validates the selection against current live devices regardless of the report's saved status. A readiness report does not grant capture consent or permission.

Save a JSON configuration, for example `artifacts/probe-config.json`. Replace every example UID with the exact value from inventory. No endpoint uses a system default.

```json
{
  "headsetMicUID": "REPLACE_WITH_HEADSET_INPUT_UID",
  "headsetOutputUID": "REPLACE_WITH_HEADSET_OUTPUT_UID",
  "xboxInputUID": "REPLACE_WITH_USB_INPUT_UID",
  "xboxOutputUID": "REPLACE_WITH_USB_OUTPUT_UID",
  "micChannel": 0,
  "xboxFirstChannel": 0,
  "xboxStereo": false,
  "requestedBuffer": 0
}
```

Channels are zero based. Use `xboxStereo: true` only if the selected USB input has at least two channels starting at `xboxFirstChannel`. A stereo headphone output does not imply a stereo input. The headset and Xbox input UIDs must differ, and their output UIDs must differ. The same full-duplex device UID may supply one input and one output.

`requestedBuffer: 0` keeps the current hardware buffers. Optional requests are 32, 64, 128, 256 or 512 frames; the device must advertise and permit the requested size. Current hardware rates must be 44.1 or 48 kHz. Change unsupported rates explicitly in Audio MIDI Setup; the probe does not silently choose a different device or rate.

Validate selection without capture:

```bash
bash scripts/routing_probe.sh --config artifacts/probe-config.json --check
```

This returns `configuration-valid` only when all four endpoints, channel selections and requested buffer capabilities check out. It opens no audio units, does not request microphone permission and is not a duplex acceptance result. Missing hardware returns failure and a report explaining the missing endpoint.

## Consented muted run

The input streams can contain private audio even though the outputs are silent. The command therefore requires the explicit `--allow-capture` flag, in addition to existing macOS microphone authorization for the process's host. The probe checks permission without requesting it. If authorization is unavailable, it returns `skipped`, opens no audio units and directs you to System Settings > Privacy & Security > Microphone. An authorization granted to Xbox Voice Deck does not necessarily cover Terminal, a terminal host, or another executable. If the command host cannot be authorized, use the native app for hardware testing and preserve this skipped result.

```bash
bash scripts/routing_probe.sh \
  --config artifacts/probe-config.json \
  --allow-capture \
  --duration 15 \
  --report artifacts/first-muted-duplex-run.json
```

The command never unmutes either path. Do not change device, sample-rate or buffer settings in another app during the run. Temporary buffer requests use the engine's existing restoration behavior; the report compares buffers again after shutdown. An interrupted or unstable run is a failure, not a shorter successful run. Ctrl+C requests orderly shutdown.

The harness checks:

- All four AUHAL units initialize and start on the explicitly selected devices. `HALUnit` verifies its device binding and reads back its noninterleaved Float32 client format.
- Both input callbacks and both output callbacks repeatedly advance; a stream stalled for over one second fails the run.
- Both route mutes stay engaged, output peak and RMS remain digital zero, and no tone starts.
- No realtime error, underrun, overrun, non-priming dropped frame or resync occurs during the run. Initial priming may deliberately discard excess queued capture frames to reach the target latency; these remain visible in both `droppedFrames` and the separate `primingDroppedFrames` counter and do not fail the run. Other drops remain failures. An error calls for investigation or a larger supported buffer, then a new report.
- Device, source, jack, rate and buffer change notifications stop the run with a visible error.
- AUHAL shutdown completes, and original buffer sizes are observed afterward.

Startup and shutdown each have a separate ten-second deadline. If a driver blocks shutdown, the report explicitly records failed cleanup and terminates the probe process. It does not treat process termination as successful AUHAL disposal.

## Reports and exit statuses

A report includes schema/probe versions, timestamps, OS and architecture, selected UIDs/IDs/rates/channels/buffers, before/active/after device observations, callback counts, drift compensation and buffer counters, output peaks, mute/tone state, shutdown result and errors. It contains no audio samples or input-level history. Review device names and UIDs before sharing publicly; these are machine metadata. Existing report files are not intentionally overwritten, so each run remains separate evidence.

| Exit | Meaning |
| --- | --- |
| 0 | Requested check passed: `configuration-valid` or `muted-run-passed`; inspect the status to distinguish them. |
| 1 | Runtime/configuration/report failure. |
| 2 | Invalid or missing arguments; no capture attempted. |
| 3 | Capture skipped because permission was not already authorized. |

Argument errors occur before a report destination is established and print to stderr. Never count skipped, configuration-only or parser runs as physical routing acceptance.

## Optional virtual devices

Installed virtual Core Audio devices appear in the same inventory; BlackHole is not required, installed or bundled by this project. At least two distinct suitable input devices and two distinct output devices must exist, and every UID must be selected explicitly. A single BlackHole 2ch device alone cannot fill both isolated input roles or both isolated output roles under this app's topology rules.

A muted virtual run can validate AUHAL startup/callbacks/shutdown. Because outputs stay zero, this harness cannot prove audible signal transfer or route isolation by observing known tones. Separate simulation tests cover route isolation; physical listening and controller tests remain required. Virtual devices also do not reproduce the independent physical clocks, input electronics or CTIA wiring of the final setup. See the [optional BlackHole instructions](../README.md#optional-blackhole).
