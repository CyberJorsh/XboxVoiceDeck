# Independent endpoint tests (0.4.0)

Stop routing, then use the test button beside a selected device in **Routing**. Only that endpoint is opened; the other three can be missing or incomplete. Tests never fall back to a system default or change hardware volume, sample rate, buffer size, saved calibration, app gains or routing mutes. Only one test can run at a time, and normal routing cannot start until it stops.

| Endpoint | Button | Behavior |
| --- | --- | --- |
| Headset microphone | Test input | Meter the chosen boom-mic channel for up to ten seconds. Speak and use the headset's physical mic mute to verify its identity. |
| Xbox audio input | Test input | Meter one or two available channels starting at the selected channel, for up to ten seconds. Play game/chat audio on the controller. A mono adapter can be tested even before Stereo Xbox input is turned off for routing. |
| Headset output | Test output… | After confirmation, play a 440 Hz tone on channel 1, then a 660 Hz tone on channel 2, one second each. A mono output plays both tones on its only channel. Fixed peak: −50 dBFS. Channels above 2 remain silent. |
| Xbox mic output | Test output… | After confirmation, play a two-second 440/660 Hz tone on channels 1/2. Fixed peak: −80 dBFS, independent of saved gain. Verify reception at the Xbox; the Mac cannot detect what the controller hears. |

Input tests show RMS, held peak, left/right levels, clip/non-finite sample count, callback count and sample rate. A mono test has no right-channel reading (displayed at the meter floor). The samples exist only in preallocated capture memory; nothing is recorded or played back. If permission is missing, **Test input** requests it when macOS permits, then requires another click to begin capture. Granting permission alone does not start audio.

Keep hardware output volume low. **The Xbox controller expects headset microphone-level audio. Depending on the USB audio adapter, an inline attenuator may be required. Software volume reduction does not guarantee electrical compatibility.** A quiet or inaudible test is not a reason to increase gain blindly. Confirm wiring, mic detection/load/bias requirements and attenuation first. Headphone/line output can also overload a USB microphone input before software meters see it.

Use **Stop test** or **Bypass All** to cancel. Tests stop when the app becomes inactive, the Mac sleeps, capture permission changes, the selected device/channel changes, or its hardware configuration disappears/changes. Closing the app shuts down its test unit. There is no automatic restart. Held readings remain visible after a test; **Test finished** describes software completion, not an automatic hardware pass.

## Implementation and verification boundaries

Each test uses one explicitly bound AUHAL through the existing `HALUnit`, at the selected device's current 44.1/48 kHz Float32 client format and buffer size. `DeckEndpointTest.c` owns the callback. Capture only computes meters; output only synthesizes bounded tones. There is no microphone-to-output connection, ring buffer, ASRC, disk access, allocation, UI work or blocking lock in this callback. Ramps smooth tone starts, transitions and endings; emergency cancellation prioritizes immediate silence.

Output is limited by fixed amplitude plus an independent final clamp. Both the sample count and continuous clock limit duration; a control-queue watchdog closes the unit even if callbacks stall. Capture is likewise bounded to ten seconds. Errors are shown in the per-endpoint result and copied diagnostics. Context memory is freed only after AUHAL disposal; failed disposal retains silenced memory until exit and reports an error.

Synthetic tests exercise input meters/clips, output levels and left/right order at 44.1/48 kHz, automatic silence, invalid bounds, cancellation races, endpoint selection, permission/restart boundaries and routing exclusion. Native UI tests use labelled simulated services. Real capture, audible output, macOS permission dialogs, Xbox reception and electrical compatibility still require the intended hardware. A per-endpoint test does not pass the simultaneous duplex or long-duration stability gate.
