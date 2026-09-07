# Xbox Voice Deck: Phase 0 architecture decision

Written before engine implementation, 2026-09-05. Scope: Phase 0 and Phase 1 only.

The 0.4.0 [independent endpoint tests](ENDPOINT_TESTS.md) use one separate AUHAL at a time while both routing paths are stopped. Capture only measures input; output only generates a fixed quiet tone. They do not change this duplex architecture or establish its physical acceptance.

## Decision

Use four Apple HAL Output Audio Units (AUHAL), each bound to an explicit Core Audio AudioDeviceID. Two units capture; two render. Each capture-to-render route owns a separate fixed-capacity single-producer/single-consumer ring and asynchronous sample-rate converter. Swift manages devices, lifetime, permissions and SwiftUI. A small C11 realtime kernel owns callbacks, preallocated memory and lock-free atomics. There are no external packages, drivers, aggregate-device mutations or network services.

```
Headset input AUHAL -> mono channel selection -> outgoing ring / ASRC
    -> safety ceiling -> extremely low output gain / mute -> Xbox output AUHAL

Xbox input AUHAL -> mono or stereo channel selection -> incoming ring / ASRC
    -> headphone gain / mute -> headset output AUHAL
```

The two rings and callback contexts are disjoint. Neither output can access the other route's input. The UI rejects identical input endpoint selections and identical output endpoint selections. This prevents direct software loopback; it cannot detect incorrectly wired analog cables, external loopback devices, or acoustic feedback. No microphone monitoring in Phase 1. Both outputs start muted on every start.

## Research and alternatives

Apple's [TN2091: Device input using the HAL Output Audio Unit](https://developer.apple.com/library/archive/technotes/tn2091/_index.html) documents enabling input on bus 1, disabling output bus 0 for a capture unit, setting CurrentDevice after enabling I/O, and obtaining capture data with AudioUnitRender. AUHAL's client PCM format uses that device's sample rate; format conversion alone does not solve independent clock drift.

The installed macOS SDK AudioUnitProperties.h and AudioHardware.h are the API source of truth. Use AudioObjectGetPropertyData to enumerate capabilities, UIDs, rates and buffer constraints; do not infer devices from system defaults or names.

* A single AVAudioEngine graph is not an arbitrary four-device router. AVAudioEngine can become a later DSP graph in manual rendering mode, but would not eliminate the inter-device clock boundary.
* Multiple AVAudioEngine instances would still need asynchronous buffering between clocks and add engine format/lifetime constraints. AUHAL gives explicit device binding and callback ownership for this first proof.
* A private aggregate device with a designated clock source and [drift correction](https://support.apple.com/en-us/102171) is a legitimate alternative. It delegates synchronization to Core Audio, but adds aggregate lifecycle, subdevice channel mapping and less visible drift/queue diagnostics. We choose independent AUHALs to expose each route's queue and failure behavior. We do not create or change an aggregate device.
* A bare AudioDeviceIOProc is also possible, but AUHAL supplies native PCM conversion and flattened channel handling without requiring a custom driver.

## Formats and synchronization

Accept 44,100 and 48,000 Hz device rates; prefer configuring hardware to 48,000 Hz in Audio MIDI Setup. Phase 1 leaves the hardware nominal rate unchanged and explicitly reports unsupported rates. All client buffers and rings are 32-bit float. Each ring stores source-rate samples. Each output consumes at its own nominal rate with exactly one adaptive conversion at the clock boundary, including when both nominal rates say 48 kHz. There is no unnecessary conversion to an intermediate 48 kHz and back. A fixed internal 48 kHz DSP graph is deferred until effects are introduced.

Use a precomputed, windowed-sinc polyphase interpolator, with low-pass cutoff adjusted for the nominal rate ratio. A bounded PI controller observes ring occupancy, filters callback-size jitter, and slowly adjusts consumption ratio within +/-2,000 ppm of the nominal input/output ratio. The destination callback is the consumer clock. Each route compensates independently; no assumption that the input and output clocks agree forever. Clock-domain metadata is diagnostic only; even an equal or unknown domain is not taken as proof of synchronization.

The producer only publishes completed samples with release semantics. The consumer reads with acquire semantics and owns its read index and fractional position. The producer never moves the consumer index. On capacity overflow, drop the incoming block and count its frames. On starvation, output silence, reset interpolation history, and re-prime. If occupancy crosses the high-water threshold, the consumer discards old samples to the target fill and crossfades back in. No unbounded queue or increasing latency. Discontinuities are counted rather than hidden.

Target fill is based on actual input/output buffer sizes, with headroom for scheduling jitter and filter history. Default requested hardware buffer is 128 frames as an initial candidate, not a claim of the lowest stable value. Offer 32/64/128/256/512 only where the device's reported range allows it, read back actual sizes, and never silently claim an unsupported request succeeded. Stability must be established on the connected hardware before lowering the buffer. No arbitrary sleeps synchronize startup: outputs stay silent until their route is primed.

## Realtime contract

Allocate rings, sample buffers, filter tables and callback contexts before AudioOutputUnitStart. No Swift code, ARC, allocation, locks, filesystem, logging, UI or networking in the C callbacks. UI parameters and meter/counter snapshots use lock-free atomics; verify this assumption at kernel creation. Control operations and Audio Unit teardown run on a serial non-realtime queue. Stop and uninitialize all callbacks before freeing their contexts. All AudioUnit OSStatus failures propagate to a visible error; a callback render error forces both paths silent until the control thread stops them.

Gain changes ramp over about 10 ms. Mute is immediate and unmute ramps in. Outgoing signal has a hard digital ceiling equivalent to a 0.95-FS clamp followed by an independently clamped output gain (default -60 dB, maximum -30 dB for Phase 1). The implementation clamps after its combined gain ramp to preserve the absolute ceiling even during transitions. This ceiling is clipping protection, not a mastering/look-ahead limiter and not electrical level conversion. Emergency bypass restores unity mic input gain, preserves both output gains and mutes, and has no DSP/soundboard to bypass in this phase. Never bypass safety protection.

## Observability, lifecycle and latency

Poll atomic snapshots on the UI/control side, not in callbacks. Display input/output RMS, held peak and clipping, ring fill, ratio correction, underruns, overruns, dropped frames, resync events and callback errors per route. Counters describe app buffers; they are not complete hardware-driver xrun accounting. Meter data never stores recordings. Diagnostics contain device metadata and aggregate signal statistics only.

Selected-device identity, alive, sample rate, buffer, data source and jack changes invalidate a running configuration. An unrelated device disappearing does not invalidate otherwise healthy selected routes. Stop both directions and show why; selected UIDs remain visible as missing. Never substitute default devices. Phase 1 requires explicit restart after the user checks wiring; automatic reconnection is deferred to Phase 6. Re-enumeration resolves volatile IDs from stable UIDs.

Estimate software latency from source buffer + target queue + destination buffer + interpolator look-ahead. Report device latency, stream latency and safety offsets separately where available. These estimates are conservative budgets, not measured acoustic/electrical end-to-end latency; scheduling, USB converters and Xbox add latency. Around 128-frame buffers at 48 kHz should leave room for a sub-20 ms software target; 512-frame buffers may exceed it. Measure with a physical impulse/loopback before making a claim.

## Phase 1 validation gate

Automated tests: ring wrap/capacity, underrun recovery, overflow/drop policy, high-water resync, ratio limits, long simulated independent-clock runs, 44.1/48 kHz conversion and signal fidelity, stereo isolation, gain ceiling/mute/bypass, malformed samples and concurrent producer/consumer access. Build the native app and enumerate real Core Audio devices. Live routing requires four valid endpoints and microphone permission; never substitute built-in speakers for a missing Xbox interface.

Current development host is an M5 Pro MacBook Pro with built-in mic/speakers only. The M1/HyperX/USB/controller topology is unverified. No soundboard or voice effects may begin until both directions pass sustained physical tests, including mismatched nominal rates, reconnects and audible drift behavior. Inspect an actual external-headset microphone data source: a device called built-in input is not proof that it is the HyperX boom mic. Cheap USB mic inputs may be mono and may clip from controller headphone level before software can reduce it.

## Phase 2 software extension

The four-AUHAL routing and clock boundary remain unchanged. An instant-attack, 100 ms-release linked-channel limiter follows SRC/input gain and precedes the separately bounded output gain/clamp. It adds zero look-ahead frames. A confirmed, generation-tracked two-second test tone replaces the outgoing mic at this stage, with sample-count and continuous-time deadlines, an independent control watchdog and latched completion/cancellation mute. Level setters and explicit mute commands are separate so later level updates cannot undo an automatic safety mute. See [CALIBRATION.md](CALIBRATION.md) for the exact tone limits, profile matching and pending hardware acceptance. All DSP and atomic state updates remain in the C callback kernel.

## Hardware-readiness corrections (0.4.1)

Buffer changes register a property listener before writing, then wait on the control queue for readback of the requested value. The acknowledgement wait has a two-second deadline and does not use sleeps. A successful HAL setter call alone is not proof that a change completed. Original buffer settings are tracked for rollback; failure to acknowledge or restore is reported. If a timed-out change remains uncertain, restoration requests the original value and requires a notification. An intervening different setting is preserved and reported. A driver call itself can still block; the app cannot cancel work inside a third-party driver. Never interpret a timeout as guaranteed unchanged hardware.

Device enumeration and listener registration run on separate background queues. Discovery coalesces overlapping requests, preserves healthy devices when another device cannot be read, and reports omitted devices. Missing stable UIDs are rejected rather than synthesized from volatile IDs. Selected missing devices still stop both paths. A three-second discovery deadline stops tests/routes and prevents restart until discovery responds; it does not enqueue unlimited retries. Results captured before a new session are discarded and refreshed.

Normal routing now uses a small control-side lifetime lock around C atomic commands. Mute, cancellation, bypass and stop never enqueue behind HAL calls. The callback threads never acquire this lock. Stop invalidates pending startup, latches both outputs muted and trips the shared C safety state before scheduling teardown. A session created after cancellation stays muted and cannot be published. Tone requests carry a cancellation generation so a delayed device query cannot revive a cancelled tone. The control queue detaches pointers under the lifetime lock before disposing/freeing callback state.

Microphone authorization is checked again before accepting startup completion. Revocation invalidates both pending startup and active routing. The UI offers Cancel startup; a stopped or cancelled session never resumes automatically.

Preflight flags default/alert-output collisions, mono USB capture and estimated software buffering above 20 ms. These are actionable hardware/setup warnings, not substitutes for actual boom-mic identification, input-level matching, attenuation, Xbox reception, measured latency or a sustained physical test. Other processes' audio on the USB output bypasses the entire app graph.
