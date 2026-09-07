# Microphone access on the testing Mac

Version 0.3.1 separates microphone permission from routing setup. **Allow microphone access** is available in Routing and Preflight even when devices are missing, the same input is selected twice, or a buffer request is invalid. The button uses Apple's `AVCaptureDevice.requestAccess(for: .audio)` API. It does not start AUHAL, capture audio or unmute anything.

## If Xbox Voice Deck is missing from Microphone settings

1. Quit the old app and open the newly built **XboxVoiceDeck.app** using Finder or `open build/DerivedData/Build/Products/Release/XboxVoiceDeck.app`. Do not run its internal executable directly. Copy diagnostics should show version **0.3.1 (4)**.
2. Open Preflight and click **Allow microphone access**. Respond to the macOS dialog. Requesting permission does not require the four endpoints to be configured.
3. If previously denied, open **System Settings → Privacy & Security → Microphone**, enable Xbox Voice Deck and return to the app. Click **Refresh permission** if needed. If macOS asks you to quit/reopen the app, do so.
4. If access is restricted, check the Mac's Screen Time or administrator policy. The app cannot override these restrictions.
5. If no dialog appears and the app remains absent, check for a dialog behind other windows and quit other copies of Xbox Voice Deck. Reopen the built app and copy its diagnostics, including the version, permission state and exact error. Preserve this evidence before considering a permission reset on that specific Mac. Do not reset permissions on another development Mac.

Before this fix, Start muted validated the complete routing setup before requesting permission. A duplicate-input or other configuration error could prevent any request. The orange error banner incorrectly offered Microphone settings for those errors, sending the user to Settings before the app had requested access. It now offers **Review setup**, with a Settings action only when permission is denied/restricted. The built app already contained `NSMicrophoneUsageDescription` and the hardened-runtime `com.apple.security.device.audio-input` entitlement; those requirements remain enabled.

## The remaining manual checks

**Physical compatibility** and **Actual HyperX boom mic** cannot be verified by the permission API. They show **Manual check required** until you record an observation below. A user observation is labelled separately from an automatic software pass, and overall physical acceptance remains pending. These manual checks do not prevent a muted input test.

The headset mic and Xbox capture must be separate inputs. Select the controller's USB adapter for **Xbox audio input**, and a separate input that actually receives the HyperX boom mic for **Headset microphone**. A built-in microphone name or an external headphone output does not establish boom-mic capture. Verify it using the headset's physical mute. For a USB adapter reporting one input channel, turn off **Stereo Xbox input** and select channel 1. Permission approval does not correct an invalid routing selection or electrical mismatch.

## Validation boundary

Regression tests reproduce the duplicate-input failure, independent permission requests, duplicate-click suppression, grant/denial handling, refreshed permission without inventory changes, and safe stop on revocation. Native UI tests use explicitly labelled simulated permission responses and open no audio devices. They cannot prove the real macOS dialog or audio hardware works on the testing M1; that must be confirmed there after rebuilding.

References: [Apple capture authorization](https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media), [Apple audio-input permission troubleshooting](https://support.apple.com/en-us/102071).
