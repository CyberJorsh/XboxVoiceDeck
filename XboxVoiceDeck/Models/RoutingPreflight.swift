import AVFoundation
import Foundation

struct PreflightCheck: Codable, Identifiable, Equatable {
    enum Status: String, Codable {
        case passed, blocked, pending, manualRequired, userObserved, reportedProblem
        var label: String {
            switch self {
            case .manualRequired: return "MANUAL CHECK REQUIRED"
            case .userObserved: return "USER OBSERVED"
            case .reportedProblem: return "PROBLEM REPORTED"
            default: return rawValue.uppercased()
            }
        }
    }
    let id: String
    let title: String
    let status: Status
    let detail: String
}

struct RoutingPreflight: Codable {
    let checks: [PreflightCheck]
    var canStartMuted: Bool { !checks.contains { $0.status == .blocked } }

    init(configuration: RoutingConfiguration, devices: [AudioEndpoint], permission: AVAuthorizationStatus,
         observations: [String: String] = [:], defaultOutput: UInt32? = nil, alertOutput: UInt32? = nil) {
        var result: [PreflightCheck] = []
        let roles = ["Headset microphone", "Headset output", "Xbox audio input", "Xbox microphone output"]
        for (index, uid) in configuration.selectedUIDs.enumerated() {
            let endpoint = devices.first { $0.uid == uid }
            let input = index == 0 || index == 2
            let capable = endpoint.map { input ? $0.inputChannels > 0 : $0.outputChannels > 0 } ?? false
            let valid = !uid.isEmpty && endpoint?.supported == true && capable
            result.append(PreflightCheck(id: "endpoint-\(index)", title: roles[index], status: valid ? .passed : .blocked,
                detail: uid.isEmpty ? "Select this endpoint in Routing." : endpoint.map {
                    "\($0.name): \($0.summary)." + (valid ? "" : " Check connection, direction and 44.1/48 kHz format.")
                } ?? "Saved device is missing. Reconnect it or explicitly select another device."))
        }
        do {
            let endpoints = try configuration.resolve(in: devices)
            result.append(PreflightCheck(id: "channels", title: "Route separation and channels", status: .passed,
                detail: "Separate capture/output roles; Xbox input uses \(configuration.xboxStereo ? "two channels" : "mono duplicated to headphones")."))
            let requested = configuration.requestedBuffer
            let invalid = requested != 0 && (![32, 64, 128, 256, 512].contains(requested) || endpoints.contains {
                $0.bufferFrames != requested && $0.bufferRange?.contains(requested) != true
            })
            result.append(PreflightCheck(id: "buffer", title: "Hardware buffer request", status: invalid ? .blocked : .passed,
                detail: invalid ? "The requested buffer is outside a selected device's reported range. Choose Keep hardware or another supported size."
                    : "\(requested == 0 ? "Keep current hardware buffers" : "Request \(requested) frames"). Write permission and actual readback are checked during startup."))
        } catch {
            result.append(PreflightCheck(id: "channels", title: "Route separation and channels", status: .blocked, detail: error.localizedDescription))
        }
        let xboxOutput = devices.first { !$0.uid.isEmpty && $0.uid == configuration.xboxOutputUID }
        let shared = xboxOutput.map { $0.id == defaultOutput || $0.id == alertOutput } ?? false
        result.append(PreflightCheck(id: "system-output", title: "Mac audio outside the limiter",
            status: shared ? .reportedProblem : .manualRequired,
            detail: (shared ? "The Xbox mic output is also selected for macOS audio or alerts. " : "") +
                "In System Settings → Sound, keep Output and Play sound effects through off the controller-connected USB adapter. Other apps can also select it directly; their audio bypasses this app's gain, mute and limiter. A quiet app test cannot certify electrical safety."))
        if let xboxInput = devices.first(where: { $0.uid == configuration.xboxInputUID }), xboxInput.inputChannels == 1 {
            result.append(PreflightCheck(id: "mono-input", title: "Mono Xbox capture", status: .manualRequired,
                detail: "This adapter reports one input channel. Turn off Stereo Xbox input in Routing. Both headphones will receive the same mono signal; stereo positioning cannot be recovered. Check controller output level because a USB mic input can clip before software gain."))
        }
        if let endpoints = try? configuration.resolve(in: devices) {
            let budgets = [(0, 3), (2, 1)].map { input, output -> Double in
                let source = endpoints[input], destination = endpoints[output]
                let inputBuffer = Double(configuration.requestedBuffer == 0 ? source.bufferFrames : configuration.requestedBuffer)
                let outputBuffer = Double(configuration.requestedBuffer == 0 ? destination.bufferFrames : configuration.requestedBuffer)
                let target = 3 * max(inputBuffer, ceil(outputBuffer * source.sampleRate / destination.sampleRate)) + 32
                return 1000 * ((inputBuffer + target + 32) / source.sampleRate + outputBuffer / destination.sampleRate)
            }
            if let budget = budgets.max(), budget >= 20 {
                result.append(PreflightCheck(id: "latency", title: "Buffer latency above target", status: .manualRequired,
                    detail: String(format: "Estimated software budget up to %.1f ms before device latency, based on the requested/current buffers. Try 128 frames, then smaller values only if stable. Keep hardware is a startup fallback, not a low-latency guarantee. Physical latency remains unmeasured.", budget)))
            }
        }
        let authorized = permission == .authorized
        result.append(PreflightCheck(id: "permission", title: "Microphone permission",
            status: authorized ? .passed : permission == .notDetermined ? .pending : .blocked,
            detail: authorized ? "macOS has granted capture access."
                : permission == .notDetermined ? "Click Allow microphone access above. No device selection or audio startup is required."
                : permission == .restricted ? "macOS policy restricts access. Check Screen Time or administrator restrictions."
                : "Enable Xbox Voice Deck in System Settings → Privacy & Security → Microphone, then Refresh permission."))
        func manualStatus(_ key: String) -> PreflightCheck.Status {
            switch observations[key] {
            case "observed working": return .userObserved
            case "problem found": return .reportedProblem
            default: return .manualRequired
            }
        }
        result.append(PreflightCheck(id: "electrical", title: "Physical compatibility", status: manualStatus("wiring"),
            detail: "Verify the exact USB adapter, CTIA splitter, input level/channel count and controller mic attenuation/bias interface. Software cannot certify these."))
        result.append(PreflightCheck(id: "boom", title: "Actual HyperX boom mic", status: manualStatus("boomMic"),
            detail: "With both outputs muted, speak and use the headset's physical mic mute. The selected input meter must follow that switch."))
        checks = result
    }
}
