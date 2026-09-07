import SwiftUI

struct DeckView: View {
    @ObservedObject var model: DeckModel
    @ObservedObject var tests: EndpointTestModel
    init(model: DeckModel) { self.model = model; self.tests = model.endpointTests }
    @State private var selectedTab = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Xbox Voice Deck").font(.largeTitle.bold())
                    Text("Phase 2 software · Physical calibration pending").foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.running ? "Stop routing" : "Start muted") { model.running ? model.stop() : model.start() }
                    .disabled(model.busy || model.permissionRequestPending || tests.busy).keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("routing.startStop")
            }
            if model.isSimulated {
                Text("SIMULATED UI TEST · No audio devices opened · Hardware unverified")
                    .font(.headline).foregroundStyle(.orange).accessibilityIdentifier("simulation.banner")
            }
            Text(model.status).font(.callout.monospaced()).textSelection(.enabled).accessibilityIdentifier("routing.status")
            if let error = model.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled).accessibilityIdentifier("routing.error")
                    Spacer()
                    Button("Review setup") { selectedTab = 1 }
                        .accessibilityIdentifier("routing.reviewSetup")
                    if model.microphoneAuthorization == .denied || model.microphoneAuthorization == .restricted {
                        Button("Microphone settings") { model.openMicrophoneSettings() }
                    }
                }.padding(10).background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            TabView(selection: $selectedTab) {
                routing.tabItem { Label("Routing", systemImage: "cable.connector") }.tag(0)
                PreflightView(model: model).tabItem { Label("Preflight", systemImage: "checklist") }.tag(1)
                levels.tabItem { Label("Meters & safety", systemImage: "waveform") }.tag(2)
                CalibrationView(model: model).tabItem { Label("Calibration", systemImage: "slider.horizontal.3") }.tag(3)
                diagnostics.tabItem { Label("Diagnostics", systemImage: "stethoscope") }.tag(4)
            }
            HStack {
                Text("Xbox incoming → headphones only. Mic → Xbox only. Sidetone off.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("BYPASS ALL") { model.bypass() }.keyboardShortcut("b", modifiers: [.command, .shift])
                    .accessibilityIdentifier("routing.bypass")
                    .help("Restore unity microphone input gain. Cancel any tone and mute its output. Preserve safe gains. There are no effects or clips. This shortcut is app-local.")
            }
        }.padding(20).frame(minWidth: 820, minHeight: 620)
    }

    private var routing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if model.microphoneAuthorization != .authorized { MicrophoneAccessView(model: model) }
                Text("Select each physical endpoint. Nothing uses the system default automatically.").font(.headline)
                endpoint("1. Headset microphone", selection: $model.configuration.headsetMicUID, input: true)
                EndpointTestView(model: model, tests: tests, role: .headsetMic)
                if let mic = model.devices.first(where: { $0.uid == model.configuration.headsetMicUID }) {
                    Picker("Boom mic channel", selection: $model.configuration.micChannel) {
                        ForEach(0..<mic.inputChannels, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                    }
                }
                Text("Confirm that the selected input is the HyperX boom microphone. A built-in microphone name alone does not prove this.")
                    .font(.caption).foregroundStyle(.secondary)
                endpoint("2. Headset output", selection: $model.configuration.headsetOutputUID, input: false)
                EndpointTestView(model: model, tests: tests, role: .headsetOutput)
                endpoint("3. Xbox audio input · USB input jack", selection: $model.configuration.xboxInputUID, input: true)
                EndpointTestView(model: model, tests: tests, role: .xboxInput)
                HStack {
                    Toggle("Stereo Xbox input", isOn: $model.configuration.xboxStereo)
                    if let usb = model.devices.first(where: { $0.uid == model.configuration.xboxInputUID }) {
                        Picker("First channel", selection: $model.configuration.xboxFirstChannel) {
                            ForEach(0..<usb.inputChannels, id: \.self) { Text("Channel \($0 + 1)").tag($0) }
                        }
                    }
                }
                Text("For a mono USB microphone jack, turn Stereo off. Mono is duplicated to both headphones. Use a proper stereo-to-mono adapter if required; do not short left and right together.")
                    .font(.caption).foregroundStyle(.secondary)
                endpoint("4. Xbox mic output · USB output jack", selection: $model.configuration.xboxOutputUID, input: false)
                EndpointTestView(model: model, tests: tests, role: .xboxOutput)
                HStack {
                    Picker("Hardware buffer request", selection: $model.configuration.requestedBuffer) {
                        Text("Keep hardware").tag(UInt32(0))
                        ForEach([32, 64, 128, 256, 512], id: \.self) { Text("\($0) frames").tag(UInt32($0)) }
                    }
                    Button("Save selection") { model.saveConfiguration() }
                    Button("Refresh devices") { model.refresh() }
                }
                Text("128 frames is the starting candidate. Unsupported requests show an error. Buffer changes affect the selected device for other apps too; original sizes are restored when routing stops. Prefer 48 kHz in Audio MIDI Setup.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Physical routes").font(.headline)
                Text("HyperX boom mic → Mac headset input → safe gain → USB output → controller MIC\nController headphones → USB input → headphone gain → Mac headset output → HyperX")
                    .font(.body.monospaced()).textSelection(.enabled)
                safetyWarning
            }.padding()
        }.disabled(model.running || model.busy)
    }

    private func endpoint(_ title: String, selection: Binding<String>, input: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: selection) {
                Text("Select a device…").tag("")
                if !selection.wrappedValue.isEmpty && !model.devices.contains(where: { $0.uid == selection.wrappedValue }) {
                    Text("MISSING — saved endpoint").tag(selection.wrappedValue)
                }
                ForEach(model.devices.filter { input ? $0.inputChannels > 0 : $0.outputChannels > 0 }) { device in
                    Text("\(device.name) [\(device.id)]\(device.supported ? "" : " — unsupported / disconnected")").tag(device.uid)
                }
            }
            .accessibilityIdentifier(title)
            if let device = model.devices.first(where: { $0.uid == selection.wrappedValue }) {
                Text(device.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    private var levels: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox("OUTGOING · HyperX microphone → Xbox microphone") {
                    VStack(alignment: .leading, spacing: 10) {
                        meter("Raw microphone", rms: model.snapshot.outgoing.inputRMS, peak: model.snapshot.outgoing.inputPeak, clips: model.snapshot.outgoing.inputClips)
                        HStack { Text("Mic input gain"); Slider(value: $model.micGain, in: 0...4).disabled(model.toneBusy); Text(String(format: "%.2f×", model.micGain)).monospacedDigit() }
                        meter("Xbox output · after safety gain", rms: model.snapshot.outgoing.outputRMS, peak: model.snapshot.outgoing.outputPeak, clips: model.snapshot.outgoing.outputClips)
                        HStack {
                            Text("Xbox output")
                            Slider(value: $model.xboxDB, in: -90 ... -30, step: 1).disabled(model.toneBusy)
                            Text("\(Int(model.xboxDB)) dB").monospacedDigit().frame(width: 60)
                            Toggle("Mute", isOn: $model.xboxMuted).toggleStyle(.switch).disabled(model.toneBusy)
                        }
                        counters(model.snapshot.outgoing)
                        Text(String(format: "Limiter reduction %.1f dB · active frames %llu · final clamp hits %llu", model.snapshot.outgoing.limiterReductionDB, model.snapshot.outgoing.limiterFrames, model.snapshot.outgoing.limitedSamples)).font(.caption)
                        Text(model.latency(outgoing: true)).font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                GroupBox("INCOMING · Xbox controller → HyperX headphones") {
                    VStack(alignment: .leading, spacing: 10) {
                        meter("Xbox input", rms: model.snapshot.incoming.inputRMS, peak: model.snapshot.incoming.inputPeak, clips: model.snapshot.incoming.inputClips)
                        Text("Input L: \(db(model.snapshot.incoming.inputLeft)) · R: \(db(model.snapshot.incoming.inputRight))\(model.configuration.xboxStereo ? "" : " (mono)")").font(.caption.monospaced())
                        meter("Headphone output", rms: model.snapshot.incoming.outputRMS, peak: model.snapshot.incoming.outputPeak, clips: model.snapshot.incoming.outputClips)
                        HStack {
                            Text("Headphones")
                            Slider(value: $model.headphoneDB, in: -90 ... 0, step: 1)
                            Text("\(Int(model.headphoneDB)) dB").monospacedDigit().frame(width: 60)
                            Toggle("Mute", isOn: $model.headphoneMuted).toggleStyle(.switch)
                        }
                        counters(model.snapshot.incoming)
                        Text(model.latency(outgoing: false)).font(.caption).foregroundStyle(.secondary)
                    }.padding(6)
                }
                Text("Meters are dBFS. Peaks and clip counts are held for the current run. Outputs start muted; unmute headphones first after confirming wiring, then cautiously test the Xbox mic. Use Calibration for the confirmed low-level tone.").font(.caption)
                safetyWarning
            }.padding()
        }.disabled(!model.running || model.busy)
    }

    private func meter(_ label: String, rms: Float, peak: Float, clips: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text("\(db(rms)) · Peak \(db(peak))").monospacedDigit()
                if clips > 0 { Text("CLIP \(clips)").foregroundStyle(.red) }
            }.font(.caption)
            ProgressView(value: max(0, min(1, (Double(20 * log10(max(rms, 0.0000316))) + 90) / 90)))
                .tint(clips > 0 ? .orange : .green)
        }
    }
    private func counters(_ s: DeckSnapshot) -> some View {
        Text("Underruns \(s.underruns) · Overruns \(s.overruns) · Dropped \(s.droppedFrames) · Resyncs \(s.resyncs)\nQueue \(s.bufferedFrames)/\(s.targetFrames) frames · Adaptive SRC \(String(format: "%.0f", s.correctionPPM)) ppm")
            .font(.caption.monospaced()).foregroundStyle(.secondary)
    }
    private func db(_ value: Float) -> String { value > 0.0000316 ? String(format: "%.1f dBFS", 20 * log10(value)) : "< −90 dBFS" }
    private var safetyWarning: some View {
        Label("The Xbox controller expects headset microphone-level audio. Depending on the USB audio adapter, an inline attenuator may be required. Software volume reduction does not guarantee electrical compatibility.", systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange).padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
    private var diagnostics: some View {
        VStack(alignment: .leading) {
            HStack { Button("Copy diagnostics") { model.copyDiagnostics() }.accessibilityIdentifier("diagnostics.copy"); Spacer(); Text("No microphone recordings or content").foregroundStyle(.secondary) }
            ScrollView { Text(model.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("diagnostics.text") }
        }.padding()
    }
}
