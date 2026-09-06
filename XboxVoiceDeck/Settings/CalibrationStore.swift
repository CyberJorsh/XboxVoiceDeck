import Foundation

struct CalibrationContext: Codable, Equatable {
    struct Endpoint: Codable, Equatable {
        let uid: String
        let sampleRate: Double
        let bufferFrames: UInt32
        let inputChannels: Int
        let outputChannels: Int
        let inputSource: UInt32?
        let outputSource: UInt32?
        init(_ device: AudioEndpoint) {
            uid = device.uid; sampleRate = device.sampleRate; bufferFrames = device.bufferFrames
            inputChannels = device.inputChannels; outputChannels = device.outputChannels
            inputSource = device.inputSource; outputSource = device.outputSource
        }
    }
    let endpoints: [Endpoint] // Headset input/output, then Xbox input/output.
    let micChannel: Int
    let xboxFirstChannel: Int
    let xboxStereo: Bool

    init(configuration: RoutingConfiguration, devices: [AudioEndpoint]) throws {
        endpoints = try configuration.resolve(in: devices).map(Endpoint.init)
        micChannel = configuration.micChannel
        xboxFirstChannel = configuration.xboxFirstChannel
        xboxStereo = configuration.xboxStereo
    }
}

struct CalibrationProfile: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let context: CalibrationContext
    let xboxDB: Double
    let micGain: Double
    let savedAt: Date
    // Software never infers controller reception or electrical certification.
    var hardwareStatus: String { "Physical calibration pending" }

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 64,
              xboxDB.isFinite, (-90 ... -30).contains(xboxDB), micGain.isFinite, (0...4).contains(micGain),
              context.endpoints.count == 4 else { throw AudioFailure("Invalid calibration profile. Stored data was left unchanged.") }
    }
    func reviewedSettings(for current: CalibrationContext, acknowledged: Bool) throws -> (xboxDB: Double, micGain: Double) {
        try validate()
        guard context == current else { throw AudioFailure("This profile's devices, channels or formats do not match. Review the current setup and save a new profile.") }
        guard acknowledged else { throw AudioFailure("Review the current wiring and hardware output controls before restoring a saved level.") }
        return (xboxDB, micGain)
    }
}

final class CalibrationStore {
    private struct Document: Codable { let version: Int; var profiles: [CalibrationProfile] }
    private let defaults: UserDefaults
    private let key = "calibration.profiles"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() throws -> [CalibrationProfile] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.profiles.count <= 64,
              Set(document.profiles.map(\.id)).count == document.profiles.count else {
            throw AudioFailure("Unsupported calibration data version or invalid profile list. Stored data was left unchanged.")
        }
        try document.profiles.forEach { try $0.validate() }
        return document.profiles
    }
    @discardableResult
    func save(name: String, context: CalibrationContext, xboxDB: Double, micGain: Double) throws -> [CalibrationProfile] {
        var profiles = try load()
        let profile = CalibrationProfile(id: UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            context: context, xboxDB: xboxDB, micGain: micGain, savedAt: Date())
        try profile.validate()
        guard profiles.count < 64 else { throw AudioFailure("Remove an unused calibration profile before saving another (limit 64).") }
        profiles.append(profile)
        try write(profiles)
        return profiles
    }
    func delete(id: UUID) throws -> [CalibrationProfile] {
        let profiles = try load().filter { $0.id != id }
        try write(profiles)
        return profiles
    }
    private func write(_ profiles: [CalibrationProfile]) throws {
        defaults.set(try JSONEncoder().encode(Document(version: 1, profiles: profiles)), forKey: key)
    }
}
