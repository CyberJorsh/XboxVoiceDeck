import SwiftUI
import UniformTypeIdentifiers

struct PreflightView: View {
    @ObservedObject var model: DeckModel
    @State private var observations: [String: String] = [:]
    @State private var exported = ""
    private let steps: [(String, String)] = [
        ("wiring", "1. Verify exact adapter, CTIA wiring and level matching in both directions."),
        ("boomMic", "2. Start muted. Confirm the HyperX meter follows its physical mic mute switch."),
        ("xboxInput", "3. Play Xbox audio. Confirm only the incoming input meter responds."),
        ("headphones", "4. Unmute headphones quietly. Check left/right if the input is stereo."),
        ("xboxMic", "5. Check the electrical interface, then calibrate from −60 dB or lower on the Xbox."),
        ("isolation", "6. Physically mute the boom mic. Xbox game audio must not return into chat."),
        ("recovery", "7. Check mute, bypass, USB removal, headset removal and sleep. Restart explicitly."),
        ("stability", "8. Run both directions for 30 minutes. Check counter changes, dropouts and latency.")
    ]
    private var preflight: RoutingPreflight {
        RoutingPreflight(configuration: model.configuration, devices: model.devices, permission: model.microphoneAuthorization)
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Prepare your wired setup").font(.title2.bold())
                Text("Check Routing first, then work through these checks. Passing software checks does not establish electrical compatibility or Xbox reception.")
                Text(preflight.canStartMuted ? "Software preflight allows a muted start" : "Resolve the blocked checks before starting")
                    .font(.headline).accessibilityIdentifier("preflight.summary")
                ForEach(preflight.checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: check.status == .passed ? "checkmark.circle" : check.status == .blocked ? "xmark.octagon" : "circle.dashed")
                            .foregroundStyle(check.status == .passed ? .green : check.status == .blocked ? .red : .orange)
                        VStack(alignment: .leading) {
                            Text("\(check.title) · \(check.status.rawValue.uppercased())").font(.headline)
                            Text(check.detail).font(.callout).foregroundStyle(.secondary)
                        }
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("preflight.\(check.id)")
                }
                Divider()
                Text("When the hardware arrives").font(.headline)
                Text("These are your observations, not automatic test results. They reset when selections change and are included in the exported report. Physical acceptance stays pending.").font(.caption)
                ForEach(steps, id: \.0) { key, instruction in
                    VStack(alignment: .leading) {
                        Text(instruction)
                        Picker("Your observation", selection: Binding(get: { observations[key] ?? "not checked" }, set: { observations[key] = $0 })) {
                            Text("Not checked").tag("not checked")
                            Text("Observed working").tag("observed working")
                            Text("Problem found").tag("problem found")
                        }.pickerStyle(.segmented).frame(maxWidth: 480)
                    }
                }
                HStack {
                    Button("Export readiness report…", action: export).accessibilityIdentifier("preflight.export")
                    Text(exported).font(.caption)
                }
                Text("The local JSON report includes build, Mac model, device names and stable UIDs, formats, counters and your observations. It contains no audio. Device identifiers can reveal hardware identity; review the file before sharing.").font(.caption).foregroundStyle(.secondary)
            }.padding()
        }
        .onChange(of: model.configuration) { _, _ in observations.removeAll(); exported = "" }
        .onChange(of: model.devices.map(\.runtimeSignature)) { _, _ in observations.removeAll(); exported = "" }
    }
    private func export() {
        let report = ReadinessReport(configuration: model.configuration, devices: model.devices, preflight: preflight,
            snapshot: model.snapshot, running: model.running, status: model.status, simulated: model.isSimulated, observations: observations)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "XboxVoiceDeck-readiness-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-" )).json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do { try report.encoded().write(to: url, options: .atomic); exported = "Report saved locally." }
            catch { model.error = "Cannot export readiness report: \(error.localizedDescription)" }
        }
    }
}
