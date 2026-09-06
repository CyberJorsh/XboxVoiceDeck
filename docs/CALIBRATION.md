# Phase 2 software safety and calibration

**Phase 2 software implemented; physical calibration pending.** The Phase 1 hardware gate is still open. No soundboard, voice effects or AI processing are included.

## Try it without hardware

Open the app's **Calibration** tab and choose **Run software safety check**, or run:

```sh
bash scripts/safety_check.sh
```

This executes six checks through the real C route/limiter/tone kernel using synthetic samples. It does not create Audio Units, open devices, capture microphones or play sound. It checks muted overload, limiter containment, incoming/outgoing isolation, bounded tone duration/level, latched completion mute, and cancellation by bypass. It cannot validate driver timing, wiring, controller reception or electrical compatibility.

`bash scripts/test.sh` provides broader XCTest, clock simulation and sanitizer coverage, including profiles and a real deadline-expiry test.

## Protection chain

```
Headset mic → adaptive SRC → ramped mic gain ──┐
                                             ├→ limiter → Xbox output gain → hard ceiling → mute → USB output
Confirmed calibration tone (replaces mic) ────┘

Xbox input → separate adaptive SRC → linked-channel limiter → headphone gain → ceiling → mute → headphones
```

The limiter is a sample-peak gain envelope with **instant attack and a 100 ms exponential release**. Threshold is 0.89 full scale, approximately −1 dBFS. Stereo channels share its envelope so balance is preserved. A final independent clamp at 0.95 × Xbox output gain remains as a last guard. Digital Xbox gain remains constrained to −90…−30 dB and defaults to −60 dB. The limiter adds **zero look-ahead/buffer frames**; this says nothing about the total hardware latency. It is not an oversampled true-peak limiter and does not measure analog voltage or controller headroom.

Input gain and gain increases ramp over about 10 ms. Output gain reductions take effect immediately to respect the new ceiling; mute is immediate. Limiter reduction, active frames, final clamp hits, input clipping and output levels have separate counters/meters. A limiter cannot repair clipping that already happened at the USB input's ADC.

## Hardware calibration workflow, when equipment arrives

Follow [HARDWARE_SETUP.md](HARDWARE_SETUP.md) first. The controller expects headset microphone-level audio. An appropriate attenuator, bias isolation and microphone loading may be required for the particular adapter. Software volume reduction does not guarantee electrical compatibility.

1. Select the exact four endpoints and channels, then **Start muted**. Verify actual capture paths and hardware formats.
2. In **Calibration**, review wiring and the adapter's hardware output setting. The acknowledgement binds to the selected device/channel/format configuration; it does not certify the electrical connection.
3. Begin at −60 dB or quieter. Explicitly unmute Xbox output only after checking the physical setup. Speak normally and adjust by 1 dB steps while checking the console's own microphone test. The software never raises gain automatically in response to silence.
4. Use the optional confirmed tone only if useful. A quiet or undetected tone is not a reason to assume the controller input needs more level.
5. Save a named profile if useful. Its status remains **Physical calibration pending** in this software pass. Neither Mac meters nor a saved profile prove Xbox reception.

## Test tone safeguards

* Fixed **440 Hz**, source peak −30 dBFS, with 10 ms endpoint fades. The tone replaces microphone samples after mic input gain and cannot enter the incoming/headphone route.
* Requires running, error-free routing; a primed, explicitly unmuted Xbox route; current setup acknowledgement; and a native confirmation dialog on every request. The engine re-enumerates devices and checks the confirmed configuration before arming.
* Every start resets Xbox output gain to **−60 dB or quieter**. A separate tone-time cap prevents subsequent gain edits from producing a tone above **−90 dBFS** at the app output. Other digital protections remain active.
* At most **two seconds**, limited by destination sample count, a continuous-clock deadline checked in the callback, and a control-queue watchdog. A stalled/resumed callback cannot resume an expired tone. Watchdogs are tied to the session and request, so an old deadline cannot cancel a newer request or reference a disposed route.
* Completion, Cancel, mute, bypass, route resync/underrun or a callback error cancels the tone and latches Xbox output mute. Tone cancellation and its mute latch share one atomic state transition, so a callback cannot observe cancellation with the previous unmuted state. Ordinary level edits cannot clear that mute. Explicit user unmute is required to resume the microphone.
* Switching away from the calibration page or app cancels the tone. Sleep stops running or pending routing, invalidates outstanding permission/start completions, and queues engine shutdown. A late completion cannot reactivate routing or overwrite a newer explicit restart. Startup remains muted. Stop/quit cancels tone state before Audio Unit disposal.

No physical tone has been tested on an Xbox in this pass. All generated-tone tests were silent memory-based processing. The UI never enables a fake connected-device state to bypass the hardware gate.

## Local profiles

Profiles use versioned JSON in UserDefaults (`calibration.profiles`). They store name, date, exact device UIDs, input channel selection, mono/stereo mode, sample rates, buffer sizes, device channel capabilities/data sources, mic gain and Xbox output gain. Volatile AudioDeviceIDs are not identity keys.

Saving uses a running configuration's actual hardware rates/buffers. Restoring requires running routing, an exact match and a fresh review of the current wiring/hardware volume controls. It mutes **both outputs before applying levels**, then consumes the review acknowledgement. Profiles never restore automatically at launch or reconnect. Startup still returns to conservative gain and mute defaults. Analog knob changes, different cables or attenuators are not detectable from a UID; rechecking them is the user's physical task.

Invalid/out-of-range profiles, corrupt JSON and unknown schema versions are rejected without overwriting existing data. Version 1 permits at most 64 profiles. Existing Phase 1 endpoint preferences remain compatible and separate. Profiles do not contain recordings or an automatically inferred “electrically safe” flag.

## Remaining gates

Actual HyperX boom-mic capture, both simultaneous physical routes, controller mic recognition, suitable attenuation/loading, analog clipping, audible artifacts, sustained driver behavior and measured end-to-end latency remain unverified. Finish those gates before soundboard or effects development.
