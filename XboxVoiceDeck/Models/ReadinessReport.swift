import Foundation

struct ReadinessReport: Codable {
    struct Endpoint: Codable {
        let role: String
        let uid: String
        let deviceID: UInt32?
        let name: String?
        let inputChannels: Int?
        let outputChannels: Int?
        let sampleRate: Double?
        let bufferFrames: UInt32?
    }
    struct Route: Codable {
        let inputCallbacks: UInt64
        let outputCallbacks: UInt64
        let underruns: UInt64
        let overruns: UInt64
        let droppedFrames: UInt64
        let primingDroppedFrames: UInt64
        let resyncs: UInt64
        let bufferedFrames: UInt32
        let targetFrames: UInt32
        let correctionPPM: Double
        let outputPeak: Float
        let muted: Bool
        init(_ s: DeckSnapshot) {
            inputCallbacks = s.inputCallbacks; outputCallbacks = s.outputCallbacks
            underruns = s.underruns; overruns = s.overruns; droppedFrames = s.droppedFrames; resyncs = s.resyncs
            primingDroppedFrames = s.primingDroppedFrames
            bufferedFrames = s.bufferedFrames; targetFrames = s.targetFrames; correctionPPM = s.correctionPPM
            outputPeak = s.outputPeak; muted = s.muted
        }
    }
    let schemaVersion: Int
    let createdAt: Date
    let appVersion: String
    let appBuild: String
    let macOS: String
    let machineModel: String
    let architecture: String
    let simulated: Bool
    let physicalAcceptance: String
    let status: String
    let running: Bool
    let configuration: RoutingConfiguration
    let endpoints: [Endpoint]
    let preflight: RoutingPreflight
    let outgoing: Route
    let incoming: Route
    let callbackError: Int32
    let userObservations: [String: String]

    init(configuration: RoutingConfiguration, devices: [AudioEndpoint], preflight: RoutingPreflight,
         snapshot: RoutingSnapshot, running: Bool, status: String, simulated: Bool,
         observations: [String: String], date: Date = Date(), bundle: Bundle = .main) {
        schemaVersion = 1; createdAt = date
        appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        appBuild = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        macOS = ProcessInfo.processInfo.operatingSystemVersionString
        machineModel = Self.systemValue("hw.model"); architecture = Self.systemValue("hw.machine")
        self.simulated = simulated; physicalAcceptance = "pending"
        self.status = status; self.running = running; self.configuration = configuration; self.preflight = preflight
        let roles = ["headsetMic", "headsetOutput", "xboxInput", "xboxOutput"]
        endpoints = configuration.selectedUIDs.enumerated().map { index, uid in
            let device = devices.first { $0.uid == uid }
            return Endpoint(role: roles[index], uid: uid, deviceID: device?.id, name: device?.name,
                inputChannels: device?.inputChannels, outputChannels: device?.outputChannels,
                sampleRate: device?.sampleRate, bufferFrames: device?.bufferFrames)
        }
        outgoing = Route(snapshot.outgoing); incoming = Route(snapshot.incoming); callbackError = snapshot.error
        userObservations = observations
    }
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
    private static func systemValue(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
}
