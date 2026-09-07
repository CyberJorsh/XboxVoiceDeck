import SwiftUI
import AVFoundation

struct MicrophoneAccessView: View {
    @ObservedObject var model: DeckModel
    private var explanation: String {
        if model.permissionRequestPending { return "Waiting for macOS. Check for its microphone permission dialog. No audio starts from this button." }
        switch model.microphoneAuthorization {
        case .authorized: return model.running ? "Microphone access granted. Audio routing is active." : "Microphone access granted. Audio stays stopped until you select devices and click Start muted."
        case .denied: return "Access was denied. Enable Xbox Voice Deck in System Settings → Privacy & Security → Microphone, then return here."
        case .restricted: return "Microphone access is restricted by macOS policy. Check Screen Time or administrator restrictions."
        default: return "Request microphone access before setting up devices. Until macOS processes this request, Xbox Voice Deck may not appear in Microphone settings. This opens no audio streams."
        }
    }
    var body: some View {
        GroupBox("Microphone access") {
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation).accessibilityIdentifier("permission.explanation")
                HStack {
                    if model.microphoneAuthorization == .notDetermined {
                        Button(model.permissionRequestPending ? "Waiting for macOS…" : "Allow microphone access") { model.requestMicrophoneAccess() }
                            .disabled(model.permissionRequestPending || model.running || model.busy)
                            .accessibilityIdentifier("permission.request")
                    }
                    if model.microphoneAuthorization == .denied || model.microphoneAuthorization == .restricted {
                        Button("Open Microphone settings", action: model.openMicrophoneSettings)
                            .accessibilityIdentifier("permission.settings")
                    }
                    Button("Refresh permission", action: model.refreshMicrophoneAuthorization)
                        .accessibilityIdentifier("permission.refresh")
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
    }
}
