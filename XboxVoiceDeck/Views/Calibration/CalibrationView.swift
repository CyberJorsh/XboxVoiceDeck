import SwiftUI

struct CalibrationView: View {
    @ObservedObject var model: DeckModel
    @State private var profileName = "My wired setup"
    @State private var showToneConfirmation = false
    @State private var toneContext: CalibrationContext?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Xbox microphone calibration").font(.title2.bold())
                Text("Physical calibration pending").font(.headline).foregroundStyle(.orange)
                Text("Software meters show digital samples, not voltage at the controller. The Xbox controller expects headset microphone-level audio. Depending on the USB audio adapter, an inline attenuator may be required. Software volume reduction does not guarantee electrical compatibility.")

                GroupBox("1 · Review the physical setup") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Check CTIA wiring, adapter suitability, attenuation and the adapter's hardware output knob. Begin with very low hardware volume. Verify the HyperX boom mic and game-audio paths independently.")
                        if let context = model.calibrationContext {
                            Text("Selected format: mic \(Int(context.endpoints[0].sampleRate)) Hz → Xbox \(Int(context.endpoints[3].sampleRate)) Hz, \(context.endpoints[3].bufferFrames) output frames").font(.caption.monospaced())
                        } else {
                            Text("Connect and select all four endpoints to enable hardware calibration. You can run the silent software check below now.").foregroundStyle(.secondary)
                        }
                        Toggle("I reviewed this wiring and the hardware output controls", isOn: Binding(
                            get: { model.calibrationReviewed },
                            set: { model.reviewedContext = $0 ? model.calibrationContext : nil }))
                            .disabled(model.calibrationContext == nil || model.toneBusy)
                            .accessibilityIdentifier("calibration.review")
                        Text("This acknowledgement is not electrical certification. Device/channel/format changes require a new review.").font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                GroupBox("2 · Check the microphone at a conservative level") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Stepper("Xbox output: \(Int(model.xboxDB)) dB", value: $model.xboxDB, in: -90 ... -30, step: 1)
                                .disabled(!model.running || model.busy || model.toneBusy)
                            Spacer()
                            Button("Reset to −60 dB") { model.xboxMuted = true; model.xboxDB = -60 }
                                .disabled(!model.running || model.busy || model.toneBusy)
                            Toggle("Mute Xbox mic", isOn: $model.xboxMuted).toggleStyle(.switch)
                                .disabled(!model.running || model.busy || model.toneBusy)
                                .accessibilityIdentifier("calibration.mute")
                        }
                        Text("Start muted. When the electrical setup is suitable, explicitly unmute and speak normally. Adjust by 1 dB while checking the Xbox's own microphone test. No automatic gain increase is performed.").font(.caption)
                        Text("Input peak: \(db(model.snapshot.outgoing.inputPeak)) · input clipping samples: \(model.snapshot.outgoing.inputClips)")
                        Text("Final output: \(db(model.snapshot.outgoing.outputRMS)) · peak: \(db(model.snapshot.outgoing.outputPeak))")
                        Text(String(format: "Limiter reduction: %.1f dB · active frames: %llu · final clamp hits: %llu", model.snapshot.outgoing.limiterReductionDB, model.snapshot.outgoing.limiterFrames, model.snapshot.outgoing.limitedSamples))
                        Text("Limiter: instant attack, 100 ms release, zero look-ahead frames. These are digital measurements; console reception and analog clipping must be checked on hardware.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                GroupBox("3 · Optional brief test tone") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("440 Hz for at most two seconds, at most −90 dBFS at the app output. Starting a tone resets Xbox gain to −60 dB or quieter and replaces microphone audio. Completion, cancellation or bypass mutes Xbox output.")
                        HStack {
                            Button("Confirm low-level tone…") {
                                toneContext = model.calibrationContext
                                showToneConfirmation = true
                            }.disabled(!model.running || model.busy || model.xboxMuted || !model.calibrationReviewed || model.toneBusy)
                            .accessibilityIdentifier("calibration.confirmTone")
                            Button("Stop tone & mute") { model.cancelTone() }.disabled(!model.toneBusy).accessibilityIdentifier("calibration.stopTone")
                            if model.toneBusy { Text("Tone active / starting").foregroundStyle(.orange) }
                        }
                        Text("Requires active routing, a reviewed setup and an explicitly unmuted Xbox output. Leaving this page or switching away from the app cancels the tone. A quiet tone does not prove compatibility.").font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                GroupBox("4 · Save or review levels") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("Profile name", text: $profileName).accessibilityIdentifier("calibration.profileName")
                            Button("Save pending profile") { model.saveProfile(name: profileName) }
                                .disabled(!model.running || model.busy || model.toneBusy)
                                .accessibilityIdentifier("calibration.saveProfile")
                        }
                        Text("Profiles store the exact device UIDs, channels, formats and levels locally. They never load automatically, unmute outputs or assert that physical calibration passed.").font(.caption)
                        ForEach(model.profiles) { profile in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text("\(profile.name) · \(Int(profile.xboxDB)) dB")
                                    Text(profile.hardwareStatus + (profile.context == model.calibrationContext ? " · matching configuration" : " · configuration differs"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Restore muted") { model.restoreProfile(profile) }
                                    .disabled(!model.running || model.busy || model.toneBusy || !model.calibrationReviewed || profile.context != model.calibrationContext)
                                    .accessibilityIdentifier("calibration.restoreProfile")
                                Button("Delete") { model.deleteProfile(profile) }.disabled(model.toneBusy)
                            }
                        }
                        Text(model.calibrationMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            .accessibilityIdentifier("calibration.message")
                    }.padding(6)
                }
                GroupBox("Without hardware · Silent software check") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Exercise the actual limiter, tone, mute, bypass and isolated route buffers using synthetic samples. This opens no audio devices and plays no sound.")
                        Button(model.offlineBusy ? "Checking…" : "Run software safety check") { model.runOfflineCheck() }
                            .disabled(model.offlineBusy || model.running || model.busy)
                            .accessibilityIdentifier("calibration.offlineCheck")
                        if let result = model.offlineResult {
                            Text(result.summary).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                .foregroundStyle(result.passed ? Color.primary : Color.red)
                                .accessibilityIdentifier("calibration.offlineResult")
                        }
                    }.padding(6)
                }
            }.padding()
        }
        .alert("Play a very low-level Xbox test tone?", isPresented: $showToneConfirmation) {
            Button("Cancel", role: .cancel) { toneContext = nil }
            Button("Play for up to 2 seconds") {
                if let toneContext { model.confirmTone(expected: toneContext) }
                toneContext = nil
            }
        } message: {
            Text("Confirm that the selected USB output is connected through suitable level-matching hardware to the controller mic input. Software reduction does not guarantee electrical compatibility. Xbox output will reset to −60 dB or lower and mute when the tone ends.")
        }
        .onDisappear { showToneConfirmation = false; toneContext = nil; model.cancelTone() }
    }
    private func db(_ value: Float) -> String { value > 0 ? String(format: "%.1f dBFS", 20 * log10(value)) : "silence" }
}
