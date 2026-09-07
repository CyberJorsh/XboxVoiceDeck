import AVFoundation
import Foundation

// The model coordinates lifecycle on the main actor. Engines deliver completions
// on the main queue; only the live engine owns Audio Units and its control queue.
protocol DeckRoutingEngine: AnyObject {
    func start(_ configuration: RoutingConfiguration, completion: @escaping (Result<[AudioEndpoint], Error>) -> Void)
    func stop(completion: @escaping ([String]) -> Void)
    func levels(micGain: Float, xboxDB: Float, headphoneDB: Float)
    func mute(_ muted: Bool, outgoing: Bool)
    func startTone(expected: CalibrationContext, completion: @escaping (Result<Void, Error>) -> Void)
    func cancelTone()
    func bypass()
    func snapshot(completion: @escaping (RoutingSnapshot?) -> Void)
    func stopSynchronously()
}

protocol DeckDeviceWatching: AnyObject {
    func watch(_ devices: [AudioEndpoint], onChange: @escaping () -> Void)
    func clear()
}

extension AudioDeviceWatcher: DeckDeviceWatching {}

struct DeckServices {
    let engine: DeckRoutingEngine
    let enumerate: () throws -> [AudioEndpoint]
    let authorization: () -> AVAuthorizationStatus
    let requestPermission: (@escaping (Bool) -> Void) -> Void
    let now: () -> TimeInterval
    let defaults: UserDefaults
    let watcher: DeckDeviceWatching?
    let runtimeEvents: Bool
    let simulated: Bool
    var endpointTester: EndpointTesting = EndpointTestEngine()

    static func live() -> DeckServices {
        DeckServices(engine: AudioRoutingEngine(), enumerate: AudioDeviceManager.enumerate,
            authorization: { AVCaptureDevice.authorizationStatus(for: .audio) },
            requestPermission: { AVCaptureDevice.requestAccess(for: .audio, completionHandler: $0) },
            now: { ProcessInfo.processInfo.systemUptime }, defaults: .standard,
            watcher: AudioDeviceWatcher(), runtimeEvents: true, simulated: false)
    }
}
