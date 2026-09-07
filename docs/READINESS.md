# Prepare before the hardware arrives

This pass prepares software and a repeatable first-run procedure. It does not certify the physical audio bridge. Soundboard and voice effects remain deferred.

## Confirm the actual equipment

Record the Mac model and macOS version from About This Mac. The intended Mac is reportedly a 14-inch model, but its exact chip/model is still to be confirmed. The app supports Apple Silicon and macOS 14 or later; a development-host build does not establish acceptance on your M1-family Mac.

The exact USB sound card and CTIA splitter are still unknown. Check their product numbers and specifications before connecting signals: USB input type (microphone versus line), mono versus true stereo capture, output level, splitter contact wiring, and suitable attenuation/bias isolation/loading for the controller microphone input. The app cannot infer analog suitability from a device name. Follow [HARDWARE_SETUP.md](HARDWARE_SETUP.md); do not use a straight cable as proof that levels are compatible.

## Prepare the Mac without opening audio devices

After cloning and installing full Xcode, run:

```sh
bash scripts/readiness_check.sh
```

This builds Release, runs the silent safety check and probe argument tests, and enumerates devices. It opens no audio streams, requests no microphone permission and plays no sound. Its local log is under `build/readiness/`, excluded from Git. Device inventory can contain identifying device names/UIDs; review logs before sharing.

For broader checks:

```sh
bash scripts/test.sh       # Unit tests, deterministic clock/fault schedules, sanitizers
bash scripts/ui_test.sh    # Native UI tests using Debug-only simulated services
```

The UI suite requires a logged-in macOS GUI session with Xcode UI automation available. An automation initialization failure is not a pass. Fixtures are explicitly labelled SIMULATED, have isolated preferences, and open no Core Audio devices. The fixture entry point is excluded from Release builds. Actual permission dialogs, drivers and microphone capture still require hardware acceptance.

The app has one control window. Closing it quits the app and invokes synchronous routing shutdown; reopening the app starts stopped with safe defaults. Use **File → Show Xbox Voice Deck** to bring the existing window forward.

## Use the app's Preflight tab

1. Click **Allow microphone access** in Routing or Preflight. This works before device selection and opens no audio streams. Then select the exact four endpoints and channels in Routing. Do not substitute defaults for a missing saved device.
2. Open Preflight. It checks individual endpoint capabilities, separation, 44.1/48 kHz, buffer requests and permission status. Blocked software configuration is rejected before engine startup; device write/readback checks still occur at startup.
3. Permission that has not yet been requested is shown as pending beside its explicit request instructions. Permission changes refresh after the request, on returning to the app and during inventory refresh; **Refresh permission** is also available. Denial offers Settings instead of another system prompt.
4. Electrical compatibility and actual boom-mic identity show **Manual check required**, not an automatic pending operation. Their checks require the physical setup and your observations. They do not block a muted input test. Recording an observation changes the label to **User observed** or **Problem reported**, never an automatic pass or electrical certification.
5. Work through the staged hardware checklist only when the devices arrive. Record Not checked, Observed working or Problem found. Observations reset when selected configuration or device runtime signatures change. These are user statements, not automated acceptance results.
6. Export a local readiness report before and after a test session. It includes timestamp, app version/build, detected Mac model/architecture, selected devices and UIDs, rates/buffers, runtime counters and observations. It contains no audio samples. Its `physicalAcceptance` remains `pending` in this preparation pass. Review identifiers before sharing.

The JSON report can also be passed to the four-endpoint probe as its configuration file. Device identities and capabilities are always checked again against the live inventory.

## Validate the four AUHAL endpoints when available

See [ROUTING_PROBE.md](ROUTING_PROBE.md). Its `--check` mode validates configuration without opening devices. Its bounded duplex mode uses the actual engine, captures the two selected inputs and keeps both outputs muted. It requires explicit capture acknowledgement and already granted permission; no audio is recorded. It verifies callbacks, client format readback, errors, device changes, silence and shutdown. It cannot prove Xbox reception, nonzero signal identity or electrical compatibility.

Optional virtual loopback can later exercise nonzero routing without physical speakers, using a deliberately isolated test configuration. No virtual driver is installed or bundled by this project. A virtual-loopback result would still not reproduce two independent physical clocks or controller analog behavior.

## Hardware-day acceptance

Use the full staged [hardware checklist](HARDWARE_SETUP.md), starting with the controller mic branch disconnected until its interface is checked. Verify the HyperX physical mute against the input meter, incoming game audio, headphone channel mapping, safe Xbox calibration and absence of game-audio return into chat. Then test stop/bypass, device removal, sleep, sustained duplex operation and measured latency.

Passing simulated tests reduces software risk. It does not replace the 30-minute physical run, listening tests or electrical checks on the intended Mac, headset, adapter and controller.
