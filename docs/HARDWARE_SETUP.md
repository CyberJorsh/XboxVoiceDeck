# Physical hardware setup

## Required equipment

* Apple Silicon Mac, macOS 14 or later. The intended target is an M1 MacBook Pro.
* HyperX Cloud III **wired** headset with its boom mic and CTIA TRRS plug.
* Xbox Series S controller with 3.5 mm CTIA headset port and a correctly labelled **headset** splitter (not a stereo headphone duplicator).
* USB audio adapter with separately accessible analog input and output.
* Appropriate 3.5 mm cables and, where needed, line/headphone-to-mic attenuation and isolation hardware. The cables alone are not proof of electrical compatibility.

## Wiring

```
                     HYPERX CLOUD III
                    headphones + boom mic
                              |
                        3.5 mm CTIA TRRS
                              |
                           MACBOOK
                       /             \
             headset mic input    headset output
                      |                 ^
                      v                 |
               outgoing route     incoming route
          safe gain + mute + clamp  gain + mute
                      |                 ^
                      v                 |
                   USB OUT           USB IN
                      |                 ^
           appropriate attenuation     |
               / bias isolation    appropriate level
                      |             matching if needed
                      v                 |
                  MIC branch       HEADPHONE branch
                       \             /
                      CTIA TRRS SPLITTER
                              |
                    Xbox controller 3.5 mm
                              |
                         XBOX SERIES S
```

The Mac's built-in microphone and output may appear as **two separate Core Audio devices**. Choose the actual headset microphone data source. If inserting the headset does not expose the boom mic, do not use the Mac's internal microphone as a substitute and call the setup complete. Verify with the headset's physical mic mute switch and a light tap on the boom housing, while keeping outputs muted. A compatible headset input adapter would then be an additional hardware requirement.

The Xbox controller's USB-C connection is **not** the audio interface. All controller audio in this design uses its analog CTIA TRRS jack. BlackHole and Xbox Remote Play are unnecessary.

## CTIA pinout

| Contact | CTIA signal |
| --- | --- |
| Tip | Left headphone |
| Ring 1 | Right headphone |
| Ring 2 | Ground |
| Sleeve | Microphone |

OMTP swaps the microphone and ground contacts. Check the splitter's wiring and labels. See [Android's wired headset specification](https://source.android.com/docs/core/interaction/accessories/headset/plug-headset-spec) for the CTIA/OMTP contact conventions; controller and adapter electrical behavior still require their own specifications and testing.

## Level matching in both directions

**The Xbox controller expects headset microphone-level audio. Depending on the USB audio adapter, an inline attenuator may be required. Software volume reduction does not guarantee electrical compatibility.**

The controller mic circuit may provide bias voltage and may depend on microphone impedance/detection. A suitable interface can require attenuation, DC blocking and correct loading; a generic straight cable does not provide these functions. Choose hardware designed for feeding a headset microphone input. Do not infer an attenuation ratio or resistor network without the particular devices' specifications.

Start with both app outputs muted, Xbox app output at **−60 dB**, and the adapter's hardware output at its lowest usable setting. The app clamps Xbox gain to at most −30 dB in Phase 1. The digital ceiling prevents software sample overload; it neither measures voltage at the controller nor protects against every electrical mismatch. Do not increase gain just because the Xbox fails to recognize a microphone; verify wiring, adapter suitability and impedance first. Never perform an initial full-volume output test.

The controller **headphone output → USB input** path also needs attention. Many cheap USB adapters expose a biased, mono microphone input, not a stereo line input. Controller headphone level can overload the adapter's ADC before app gain reduction. Begin with low controller headphone volume. Use appropriate attenuation or a stereo line-input interface if needed. Do not tie stereo left and right outputs together with a passive short; use a correctly designed summing adapter or capture one channel. Software cannot recover stereo from a mono adapter or undo analog clipping.

## Keep other Mac audio off the controller microphone

Before connecting the USB output to the controller mic branch, open **System Settings → Sound**. Set both **Output** and **Play sound effects through** to a destination other than that USB adapter. Check other audio applications too: they can select the adapter directly even when it is not the system default. Xbox Voice Deck cannot mute or limit those streams. The app warns when its Xbox output matches macOS's default or alert output, but absence of that warning is not electrical certification or proof that no other app uses the device.

## Phase 1 setup and physical acceptance checklist

1. Leave the USB output disconnected from the controller mic branch until its level/interface suitability is checked. Connect the HyperX directly to the Mac.
2. Connect the USB sound card to the Mac. In Audio MIDI Setup choose 48 kHz for its input/output and the headset where supported; 44.1 kHz also works. The app will not change nominal sample rates.
3. Plug the CTIA headset splitter into the controller. Connect its headphone branch to the USB input, using appropriate input-level matching.
4. Select **Headset microphone**, **Headset output**, **Xbox audio input**, and **Xbox mic output** explicitly in the app. Select the real mic channel. Select Mono for a one-channel USB input. Outputs use the first one/two channels.
5. Choose 128 frames initially, or **Keep hardware** if the adapter cannot accept that request. The app shows a failure instead of silently ignoring an unsupported buffer request.
6. Click **Start muted** and grant microphone access. With both outputs still muted, speak into the HyperX and operate its physical mic mute; verify the raw-mic meter responds accordingly. Play Xbox game audio and check only the incoming Xbox meter responds. Headset removal must stop routing.
7. Unmute headphone output at −20 dB or lower, raise gradually and confirm game/chat audio. Check left/right with known stereo content if the USB input is genuinely stereo.
8. After checking level matching, connect USB output through the suitable interface/attenuator to the controller microphone branch. Keep Xbox output at −60 dB. Unmute and speak normally; check the console's own mic meter or a trusted party-chat test. Adjust by 1 dB steps. Do not equate a Mac meter with Xbox reception.
9. With the HyperX physically muted, play Xbox audio. The outgoing app meter and Xbox microphone test must stay silent. Verify no game audio returns into chat. Inspect physical wiring and controller settings if it does.
10. Verify **Mute**, **Stop routing**, and **BYPASS ALL**. Bypass resets microphone input gain to 1× and preserves both output mutes and gains. It does not unmute a muted mic. If a calibration tone is active, bypass cancels it and mutes Xbox output. There are no voice effects yet.
11. Run both directions for at least 30 minutes. Record counter differences after initial priming; listen for dropouts, pitch warble and growing delay. Try 44.1→48 and 48→44.1 kHz combinations. Changing a running rate intentionally stops routing; restart after configuration changes.
12. Unplug/replug USB, remove/reinsert the headset, and change a selected device's buffer/rate. Both paths must stop or stay silent with a visible status. Reconnect must never choose a different default device. Check selections and restart manually.
13. Reduce to 64 then 32 frames only if supported and sustained tests remain stable. Increase to 256/512 if necessary and note the latency tradeoff. Measure electrical latency with an appropriate isolated loopback before claiming a sub-20 ms result.
14. Save the endpoint configuration and copy diagnostics. Startup still resets levels conservatively. The [Phase 2 calibration screen](CALIBRATION.md) supports confirmed bounded tones and explicitly reviewed profile restoration, always with physical calibration marked pending until the hardware gate is addressed.

Do not advance to voice effects or soundboard development until both physical directions pass. The current development host only exposed a built-in mic and speakers, so this checklist remains a required user hardware gate.
