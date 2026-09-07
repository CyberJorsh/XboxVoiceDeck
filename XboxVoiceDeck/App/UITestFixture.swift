#if DEBUG
import AVFoundation
import Foundation

// Debug-only fixtures are opt-in and cannot construct live audio services.
// Their counters describe simulated control flow, never hardware validation.
enum UITestFixture {
    @MainActor static func makeModel(environment: [String: String]) -> DeckModel? {
        guard environment["XVD_UI_TESTING"] == "1" else { return nil }
        let scenario = environment["XVD_UI_SCENARIO"] ?? "ready"
        let inventory = scenario == "missing" || scenario.hasPrefix("permission-") ? [] : endpoints
        let permission = FixtureMicrophonePermission(scenario: scenario)
        let engine = FixtureRoutingEngine(endpoints: inventory, holdStart: scenario == "startup-pending")
        let suite = "com.justjorshin.XboxVoiceDeck.UITestFixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = DeckModel(services: DeckServices(engine: engine, enumerate: { inventory },
            authorization: { permission.value }, requestPermission: { completion in
                permission.value = scenario == "permission-request" ? .authorized : .denied
                completion(permission.value == .authorized)
            },
            now: { ProcessInfo.processInfo.systemUptime }, defaults: defaults, watcher: nil,
            runtimeEvents: true, simulated: true, endpointTester: FixtureEndpointTester(), discover: scenario == "system-output" ? { completion in
                completion(.success(DeviceInventory(devices: inventory, defaultOutput: 9002, alertOutput: 9002)))
            } : nil))
        model.configuration = configuration
        model.status = "SIMULATED TEST SESSION — no hardware audio"
        return model
    }

    static let configuration = RoutingConfiguration(headsetMicUID: "fixture.headset", headsetOutputUID: "fixture.headset",
        xboxInputUID: "fixture.xbox", xboxOutputUID: "fixture.xbox")
    static let endpoints = [endpoint(id: 9001, uid: "fixture.headset", name: "SIMULATED Headset", inputs: 1),
                            endpoint(id: 9002, uid: "fixture.xbox", name: "SIMULATED USB Xbox", inputs: 2)]
    private static func endpoint(id: UInt32, uid: String, name: String, inputs: Int) -> AudioEndpoint {
        AudioEndpoint(id: id, uid: uid, name: name, manufacturer: "UI test fixture only",
            inputChannels: inputs, outputChannels: 2, sampleRate: 48000, bufferFrames: 128, bufferRange: 32...512,
            supportedRates: "44100, 48000", alive: true, clockDomain: 0,
            inputLatency: 0, outputLatency: 0, inputSafety: 0, outputSafety: 0,
            inputStreamLatency: 0, outputStreamLatency: 0, inputSource: nil, outputSource: nil,
            inputJack: 1, outputJack: 1)
    }
}

private final class FixtureMicrophonePermission {
    var value: AVAuthorizationStatus
    init(scenario: String) {
        value = scenario.hasPrefix("permission-") ? .notDetermined : scenario == "denied" ? .denied : .authorized
    }
}

private final class FixtureEndpointTester: EndpointTesting {
    private var value: DeckEndpointTestSnapshot?
    private var deadline: TimeInterval = 0
    func start(_ request: EndpointTestRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        var value = DeckEndpointTestSnapshot(); value.active = true
        value.rms = request.role.input ? 0.05 : 0.00005; value.peak = value.rms
        self.value = value
        deadline = ProcessInfo.processInfo.systemUptime + (request.role.input ? 10 : 2)
        completion(.success(()))
    }
    func stop(completion: @escaping ([String]) -> Void) { value?.active = false; completion([]) }
    func snapshot(completion: @escaping (DeckEndpointTestSnapshot?) -> Void) {
        value?.callbacks += 1
        value?.active = ProcessInfo.processInfo.systemUptime < deadline
        completion(value)
    }
    func stopSynchronously() { value?.active = false }
}

private final class FixtureRoutingEngine: DeckRoutingEngine {
    let endpoints: [AudioEndpoint]
    private var running = false
    private var outgoingMuted = true
    private var incomingMuted = true
    private var toneActive = false
    private var toneDeadline: TimeInterval = 0
    private var callbacks: UInt64 = 0
    let holdStart: Bool
    init(endpoints: [AudioEndpoint], holdStart: Bool = false) { self.endpoints = endpoints; self.holdStart = holdStart }
    func start(_ configuration: RoutingConfiguration, completion: @escaping (Result<[AudioEndpoint], Error>) -> Void) {
        if holdStart { return } // Simulate a pending driver call without opening hardware.
        do {
            let selected = try configuration.resolve(in: endpoints)
            running = true; outgoingMuted = true; incomingMuted = true
            completion(.success(selected))
        } catch { completion(.failure(error)) }
    }
    func stop(completion: @escaping ([String]) -> Void) { stopSynchronously(); completion([]) }
    func levels(micGain: Float, xboxDB: Float, headphoneDB: Float) {}
    func mute(_ muted: Bool, outgoing: Bool) {
        if outgoing { outgoingMuted = muted; if muted { cancelTone() } }
        else { incomingMuted = muted }
    }
    func startTone(expected: CalibrationContext, completion: @escaping (Result<Void, Error>) -> Void) {
        guard running, !outgoingMuted, !toneActive else {
            completion(.failure(AudioFailure("Simulated route must be running and explicitly unmuted."))); return
        }
        toneActive = true; toneDeadline = ProcessInfo.processInfo.systemUptime + 2
        completion(.success(()))
    }
    func cancelTone() { if toneActive { outgoingMuted = true }; toneActive = false }
    func bypass() { cancelTone() }
    func snapshot(completion: @escaping (RoutingSnapshot?) -> Void) {
        guard running else { completion(nil); return }
        if toneActive && ProcessInfo.processInfo.systemUptime >= toneDeadline { cancelTone() }
        callbacks += 1
        var value = RoutingSnapshot()
        value.outgoing.inputCallbacks = callbacks; value.outgoing.outputCallbacks = callbacks
        value.incoming.inputCallbacks = callbacks; value.incoming.outputCallbacks = callbacks
        value.outgoing.muted = outgoingMuted; value.incoming.muted = incomingMuted
        value.outgoing.toneActive = toneActive
        completion(value)
    }
    func stopSynchronously() { cancelTone(); running = false; outgoingMuted = true; incomingMuted = true }
}
#endif
