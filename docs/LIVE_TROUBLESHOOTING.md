# Live hardware troubleshooting

These steps preserve the existing Xbox output protection. Hardware gain and endpoint selection are local Mac settings; cloning or updating the repository does not apply them.

## Verify the microphone before increasing Xbox output

1. Stop routing and identify the actual boom-mic input. A headset plugged into the Mac's headset jack can appear as **External Microphone**, separately from **External Headphones**. A similarly named USB input is not necessarily that microphone.
2. Select that input explicitly as **Headset microphone**. Keep **Xbox audio input** on the separate controller-connected adapter. For an adapter with one capture channel, select mono.
3. Use the input test while speaking and operate the headset's physical mute. Confirm the selected input responds to the boom mic and its mute, rather than game audio or the Mac's internal mic. A moving meter alone does not identify the source.
4. Inspect that device's **Input** controls in Audio MIDI Setup. Check hardware mute and gain before using the app's mic gain. If capture is too quiet, make a small input-gain adjustment and repeat the test. Check normal speech and louder speech for clipping; do not copy another adapter's gain blindly.
5. Start routing muted. Xbox output resets to **−60 dB or quieter** on every start. After reviewing the electrical connection, explicitly unmute Xbox mic and calibrate gradually using the [calibration workflow](CALIBRATION.md). Check the first account's headset-mic setting is enabled and mute the listening account's microphone.

The app's Xbox output gain is capped at **−30 dB**. Very quiet final output can mean the wrong input or weak capture, even at that cap. For example, approximately −84 dBFS input plus −30 dB output gain produces approximately −114 dBFS output at unity mic gain. Raising the output ceiling would not correct the source selection.

Hardware microphone gain, app **Mic input gain**, app **Xbox output gain**, and the adapter's hardware output volume are separate controls. Audio MIDI Setup changes affect the device outside this app and are not automatically applied by a saved app calibration profile. Software gain reduction does not guarantee electrical compatibility with the controller microphone input.

## Gameplay reaches the other account instead of voice

Verify the cable destinations by their port labels:

| From | To |
| --- | --- |
| Controller splitter headphone branch | USB adapter input |
| USB adapter output, through suitable level matching | Controller splitter microphone branch |
| HyperX headset | Mac headset jack, or the explicitly selected compatible headset interface |

With the listening account's microphone muted, repeat the same loud game passage for each test. Change one thing at a time and restore temporary mutes deliberately before testing voice.

* Physically mute the HyperX mic and check whether game sounds still reach the party.
* Stop routing. If the party still hears gameplay while the app has released its audio units, the app's active routes are not required for that feed. Inspect other audio applications, system/alert output selection, adapter monitoring and the physical path. A software mute readback does not prove analog isolation.
* Check Audio MIDI Setup's **Thru** setting if exposed. Do not assume a hidden monitoring control is the cause merely because the adapter provides one.
* If the controller can stay powered on using batteries, compare with its USB cable disconnected. A change can help isolate the setup, but does not by itself prove a ground loop or a permanent fix.
* With routing stopped, a direct HyperX-to-controller party test can establish whether the headset, controller and party settings work without the bridge.

Turning off Xbox **Headset mic** disables both the unwanted feed and your voice; it is an isolation test, not a transmission fix. Recheck louder game sounds after an apparent improvement.

## Buzz in the HyperX headphones

If lowering headphone volume reduces both game and buzz, temporarily muting the Xbox capture input can establish whether the noise arrives through that path. Inspect the USB input's hardware gain and controller headphone level. A microphone input can be overloaded before the app sees samples; reducing app headphone gain cannot repair that. Restore the input mute after the test and confirm game audio returns. See [level matching](HARDWARE_SETUP.md#level-matching-in-both-directions).

## Recorded session: September 7, 2026

Release **0.4.1 (6)**, source commit `7c0e02b`, was exercised on an Apple Silicon development Mac reporting **Mac17,9**, macOS **26.6.2**. This was not M1 acceptance testing. The setup exposed an Apple headset-jack microphone/output, a C-Media USB adapter with one input/two outputs, and separate JinAudio USB input/output endpoints.

| Observation or change | Evidence and limit |
| --- | --- |
| Stop routing released app audio I/O | Core Audio process inventory showed no running app input/output and empty device lists during the stopped test. The user still reported party gameplay at that point. |
| Monitoring and USB isolation | Thru reported off. Temporarily reducing separate adapter monitoring gain from 0 to −15 dB made no audible difference and was restored. Controller USB removal initially appeared to stop leakage, but leakage later recurred while wireless. No circuit cause was established. |
| Incoming hardware gain reduced from +20 to 0 dB | The user reported headphone buzz stopped after this change; the adapter input was unmuted afterward. This is a setting for the tested adapter, not a universal recommendation. |
| Analog cables swapped to the intended port directions | The user subsequently reported no gameplay return, but still no voice. Direct headset-to-controller voice had worked. Sustained absence of leakage remains unverified. |
| Capture source mismatch investigated | At reported Xbox gain −30 dB, selected JinAudio capture was around −84 dBFS RMS while the Apple headset-jack input reached roughly −31.2 dBFS RMS. Levels supported testing the headset-jack source but did not identify audio content. |
| Corrected selection verified | Saved configuration and live app Core Audio I/O then used **External Microphone** (`BuiltInHeadphoneInputDevice`) alongside the separate Xbox USB input. Numerical device IDs changed during testing and are not portable configuration keys. |
| Headset microphone hardware gain boosted by 6 dB | Audio MIDI Setup changed the Apple input from **−6 to 0 dB**, with readback verified. The Xbox output cap was unchanged. |
| Input capture after the boost | A five-second input-only probe reported headset-jack peak **−13.6 dBFS**, final RMS approximately **−24.4 dBFS**, zero input clips and zero callback errors. All temporary capture units closed successfully. This was not a recording or an Xbox reception measurement. |
| Silent software checks | All six checks in `scripts/safety_check.sh` passed, including incoming/outgoing isolation. These checks do not exercise the analog bridge. |

Temporary device mute tests were restored. No app source code, output safety cap, voice effects or soundboard functionality changed during this session. Raw machine inventories, temporary probes with machine-specific device bindings, and private diagnostic artifacts remain local rather than being published.

**Still pending:** confirmation that the second party account hears the boom mic after the source correction/boost, repeated no-gameplay-return testing, electrical compatibility and calibration, sustained duplex stability, recovery tests, measured latency and acceptance on the intended M1 Mac. Use the [hardware checklist](HARDWARE_SETUP.md#phase-1-setup-and-physical-acceptance-checklist) before advancing to effects or soundboard development.
