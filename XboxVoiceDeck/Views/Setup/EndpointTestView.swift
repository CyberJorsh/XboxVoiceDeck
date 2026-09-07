import SwiftUI

struct EndpointTestView: View {
    @ObservedObject var model: DeckModel
    @ObservedObject var tests: EndpointTestModel
    let role: EndpointRole
    @State private var confirmation: EndpointTestRequest?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(role.input ? "Test input" : "Test output…") {
                    guard let request = model.prepareEndpointTest(role) else { return }
                    if role.input { model.startEndpointTest(request) }
                    else { confirmation = request; confirming = true }
                }
                .disabled(tests.busy || model.running || model.busy || model.permissionRequestPending)
                .accessibilityIdentifier("endpoint.test.\(role.rawValue)")
                if tests.busy && tests.request?.role == role {
                    Button("Stop test") { tests.stop() }.accessibilityIdentifier("endpoint.stop.\(role.rawValue)")
                }
                Text(role.input ? "10 seconds · input meter only" : role == .xboxOutput ? "2 seconds · −80 dBFS peak" : "2 seconds · left then right · −50 dBFS peak")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if tests.request?.role == role {
                Text(tests.message).font(.caption).accessibilityIdentifier("endpoint.status.\(role.rawValue)")
                ProgressView(value: min(1, max(0, Double(tests.reading.rms))))
                    .accessibilityIdentifier("endpoint.meter.\(role.rawValue)")
                Text(String(format: "RMS %.1f dBFS · peak %.1f dBFS · L %.1f / R %.1f dBFS · clips %llu · callbacks %llu · %.0f Hz",
                    db(tests.reading.rms), db(tests.reading.peak), db(tests.reading.left), db(tests.reading.right),
                    tests.reading.clips, tests.reading.callbacks, tests.request?.device.sampleRate ?? 0))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .alert("Play a quiet output test?", isPresented: $confirming) {
            Button("Cancel", role: .cancel) { confirmation = nil }
            Button("Play quiet test") {
                if let confirmation { model.startEndpointTest(confirmation) }
                confirmation = nil
            }.accessibilityIdentifier("endpoint.confirm")
        } message: {
            Text("Selected: \(confirmation?.device.name ?? "none") [\(confirmation?.device.id ?? 0)]. " +
                 (role == .xboxOutput
                  ? "The Xbox controller expects headset microphone-level audio. Depending on the USB audio adapter, an inline attenuator may be required. Software volume reduction does not guarantee electrical compatibility. This test is fixed at −80 dBFS peak."
                  : "Keep hardware volume low. Left then right tones play at −50 dBFS peak; a mono output plays both tones on its only channel.") +
                 " Stops after two seconds. Existing routing remains stopped; saved gains and mutes are unchanged.")
        }
    }
    private func db(_ value: Float) -> Double { 20 * log10(max(Double(value), 0.000001)) }
}
