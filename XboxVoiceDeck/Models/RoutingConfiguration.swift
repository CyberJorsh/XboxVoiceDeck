import Foundation

struct RoutingConfiguration: Codable, Equatable {
    var headsetMicUID = ""
    var headsetOutputUID = ""
    var xboxInputUID = ""
    var xboxOutputUID = ""
    var micChannel = 0
    var xboxFirstChannel = 0
    var xboxStereo = true
    var requestedBuffer: UInt32 = 128 // 0 means retain current hardware settings.

    var selectedUIDs: [String] { [headsetMicUID, headsetOutputUID, xboxInputUID, xboxOutputUID] }

    func resolve(in devices: [AudioEndpoint]) throws -> [AudioEndpoint] {
        guard [0, 32, 64, 128, 256, 512].contains(requestedBuffer) else {
            throw AudioFailure("Choose Keep hardware or a 32/64/128/256/512-frame buffer request.")
        }
        guard !selectedUIDs.contains("") else { throw AudioFailure("Select all four endpoints explicitly.") }
        guard headsetMicUID != xboxInputUID else {
            let name = devices.first { $0.uid == headsetMicUID }?.name ?? "the same saved input"
            throw AudioFailure("Headset microphone and Xbox input must be different devices. Both currently select \(name). Set Xbox input to the controller's USB adapter and select a separate input that actually receives the HyperX boom mic.")
        }
        guard headsetOutputUID != xboxOutputUID else { throw AudioFailure("Headset and Xbox outputs must be different devices to keep the paths isolated.") }
        let endpoints = try selectedUIDs.map { uid in
            guard let device = devices.first(where: { $0.uid == uid }) else { throw AudioFailure("MISSING: selected device \(uid). Reconnect it or select another endpoint.") }
            guard device.alive else { throw AudioFailure("DISCONNECTED: \(device.name)") }
            guard device.supported else { throw AudioFailure("UNSUPPORTED FORMAT: \(device.name) is \(Int(device.sampleRate)) Hz. Select 44.1 or 48 kHz in Audio MIDI Setup.") }
            guard device.bufferFrames > 0 && device.bufferFrames <= 4096 else { throw AudioFailure("Unsupported buffer size on \(device.name).") }
            guard requestedBuffer == 0 || device.bufferFrames == requestedBuffer || device.bufferRange?.contains(requestedBuffer) == true else {
                throw AudioFailure("\(device.name) does not report support for \(requestedBuffer) frames. Choose Keep hardware or a supported size.")
            }
            return device
        }
        guard micChannel >= 0, micChannel < endpoints[0].inputChannels,
              xboxFirstChannel >= 0, xboxFirstChannel + (xboxStereo ? 2 : 1) <= endpoints[2].inputChannels else {
            throw AudioFailure("Selected input channels are unavailable. For a mono USB mic input, turn off Stereo Xbox input in Routing and select its available channel.")
        }
        guard endpoints[1].outputChannels > 0, endpoints[3].outputChannels > 0 else { throw AudioFailure("Selected output has no output channels.") }
        guard endpoints.allSatisfy({ $0.inputChannels <= 32 && $0.outputChannels <= 32 }) else {
            throw AudioFailure("Phase 1 supports up to 32 device channels, with one selected mic channel and one mono/stereo Xbox pair.")
        }
        return endpoints
    }
}
