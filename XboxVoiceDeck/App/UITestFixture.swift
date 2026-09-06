#if DEBUG
import AVFoundation
import Foundation

// Debug-only fixtures are opt-in and cannot construct live audio services.
// Their counters describe simulated control flow, never hardware validation.
enum UITestFixture {
    @MainActor static func makeModel(arguments: [String]) -> DeckModel? {
        guard arguments.contains("--ui-testing") else { return nil }
        let scenario = arguments.firstIndex(of: "--ui-scenario").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        } ?? "ready"
        let inventory = scenario == "missing" ? [] : endpoints
        let engine = FixtureRoutingEngine(endpoints: inventory)
        let suite = "com.justjorshin.XboxVoiceDeck.UITestFixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = DeckModel(services: DeckServices(engine: engine, enumerate: { inventory },
            authorization: { scenario == "denied" ? .denied : .authorized }, requestPermission: { $0(false) },
            now: { ProcessInfo.processInfo.systemUptime }, defaults: defaults, watcher: nil,
            runtimeEvents: true, simulated: true))
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

private final class FixtureRoutingEngine: DeckRoutingEngine {
    let endpoints: [AudioEndpoint]
    private var running = false
    private var outgoingMuted = true
    private var incomingMuted = true
    private var toneActive = false
    private var toneDeadline: TimeInterval = 0
    private var callbacks: UInt64 = 0
    init(endpoints: [AudioEndpoint]) { self.endpoints = endpoints }
    func start(_ configuration: RoutingConfiguration, completion: @escaping (Result<[AudioEndpoint], Error>) -> Void) {
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
