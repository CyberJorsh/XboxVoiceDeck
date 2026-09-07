import AVFoundation
import Foundation

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
