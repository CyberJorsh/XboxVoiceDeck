import Foundation
import AudioToolbox
import OSLog

struct RoutingSnapshot {
    var outgoing = DeckSnapshot()
    var incoming = DeckSnapshot()
    var error: Int32 = 0
}

private final class RoutingSession {
    var units: [HALUnit] = []
    var captures: [OpaquePointer] = []
    var outputs: [OpaquePointer] = []
    let safety: OpaquePointer
    var outgoing: OpaquePointer?
    var incoming: OpaquePointer?
    let endpoints: [AudioEndpoint]
    let configuration: RoutingConfiguration
    private var closed = false

    init(configuration: RoutingConfiguration, endpoints: [AudioEndpoint]) throws {
        self.endpoints = endpoints
        self.configuration = configuration
        guard let safety = DeckSafetyCreate() else { throw AudioFailure("Cannot create lock-free safety state.") }
        self.safety = safety
        outgoing = DeckRouteCreate(endpoints[0].sampleRate, endpoints[3].sampleRate,
                                   endpoints[0].bufferFrames, endpoints[3].bufferFrames, 1, true)
        incoming = DeckRouteCreate(endpoints[2].sampleRate, endpoints[1].sampleRate,
                                   endpoints[2].bufferFrames, endpoints[1].bufferFrames, configuration.xboxStereo ? 2 : 1, false)
        guard let outgoing, let incoming else { throw AudioFailure("Cannot allocate realtime routes or unsupported format.") }
        // The route references are intentionally fixed here. Xbox capture has no
        // reference to the outgoing route, including in the realtime C callbacks.
        try add(device: endpoints[0], capture: true, route: outgoing, channel: configuration.micChannel)
        try add(device: endpoints[2], capture: true, route: incoming, channel: configuration.xboxFirstChannel)
        try add(device: endpoints[3], capture: false, route: outgoing, channel: 0)
        try add(device: endpoints[1], capture: false, route: incoming, channel: 0)
        for unit in units { try unit.start() }
    }
    private func add(device: AudioEndpoint, capture: Bool, route: OpaquePointer, channel: Int) throws {
        let unit = try HALUnit(device: device, capture: capture)
        units.append(unit)
        if capture {
            guard let context = DeckCaptureCreate(route, safety, unit.unit, unit.channels, UInt32(channel), unit.maxFrames) else {
                throw AudioFailure("Cannot allocate capture buffers.")
            }
            captures.append(context)
            try unit.attach(context: UnsafeMutableRawPointer(context))
        } else {
            guard let context = DeckOutputCreate(route, safety, unit.channels, unit.maxFrames) else {
                throw AudioFailure("Cannot allocate output buffers.")
            }
            outputs.append(context)
            try unit.attach(context: UnsafeMutableRawPointer(context))
        }
    }
    func snapshot() -> RoutingSnapshot {
        RoutingSnapshot(outgoing: DeckRouteSnapshot(outgoing!), incoming: DeckRouteSnapshot(incoming!), error: DeckSafetyError(safety))
    }
    func shutdown() -> [String] {
        guard !closed else { return [] }
        closed = true
        if let outgoing { DeckRouteSetMuted(outgoing, true) }
        if let incoming { DeckRouteSetMuted(incoming, true) }
        DeckSafetyTrip(safety, -1)
        var errors: [String] = []
        for unit in units.reversed() {
            let status = unit.close()
            if status != noErr { errors.append("AUHAL shutdown error: \(status)") }
        }
        let safeToFree = units.allSatisfy(\.disposed)
        // Dispose every Audio Unit before releasing any callback context.
        units.removeAll()
        guard safeToFree else {
            // An exceptional HAL disposal failure must not become a callback
            // use-after-free. Quarantine these silenced C allocations until exit.
            errors.append("HAL could not dispose an audio unit. Realtime memory retained safely; quit and reopen the app.")
            return errors
        }
        captures.forEach(DeckCaptureDestroy)
        outputs.forEach(DeckOutputDestroy)
        if let outgoing { DeckRouteDestroy(outgoing) }
        if let incoming { DeckRouteDestroy(incoming) }
        DeckSafetyDestroy(safety)
        return errors
    }
    deinit { for error in shutdown() { Logger.audio.error("\(error, privacy: .public)") } }
}

extension Logger {
    static let audio = Logger(subsystem: "com.justjorshin.XboxVoiceDeck", category: "Audio")
}

// All mutable state is private and confined to queue. Public methods enqueue
// work; the sole synchronous entry is the application-termination barrier.
final class AudioRoutingEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "XboxVoiceDeck.audio-control", qos: .userInitiated)
    private var session: RoutingSession?
    private var originalBuffers: [(device: AudioEndpoint, requested: UInt32)] = []
    private var toneWatchdog: DispatchWorkItem?
    private var toneID: UUID?

    func start(_ configuration: RoutingConfiguration, completion: @escaping (Result<[AudioEndpoint], Error>) -> Void) {
        queue.async {
            do {
                let previousErrors = self.shutdown()
                guard previousErrors.isEmpty else { throw AudioFailure(previousErrors.joined(separator: "\n")) }
                let devices = try AudioDeviceManager.enumerate()
                let selected = try configuration.resolve(in: devices)
                if configuration.requestedBuffer != 0 {
                    for device in Dictionary(grouping: selected, by: \.uid).values.compactMap(\.first) {
                        self.originalBuffers.append((device, configuration.requestedBuffer))
                        try AudioDeviceManager.setBuffer(configuration.requestedBuffer, device: device)
                        Logger.audio.info("Buffer request \(configuration.requestedBuffer) for device \(device.id)")
                    }
                }
                let actual = try configuration.resolve(in: AudioDeviceManager.enumerate())
                self.session = try RoutingSession(configuration: configuration, endpoints: actual)
                Logger.audio.info("Routing started with explicit devices \(actual.map { String($0.id) }.joined(separator: ","), privacy: .public)")
                DispatchQueue.main.async { completion(.success(actual)) }
            } catch {
                let cleanupErrors = self.shutdown()
                Logger.audio.error("Audio startup failed: \(error.localizedDescription, privacy: .public)")
                let failure = AudioFailure(([error.localizedDescription] + cleanupErrors).joined(separator: "\n"))
                DispatchQueue.main.async { completion(.failure(failure)) }
            }
        }
    }
    func stop(completion: @escaping ([String]) -> Void = { _ in }) {
        queue.async {
            let errors = self.shutdown()
            DispatchQueue.main.async { completion(errors) }
        }
    }
    @discardableResult private func shutdown() -> [String] {
        toneWatchdog?.cancel(); toneWatchdog = nil
        toneID = nil
        var errors = session?.shutdown() ?? []
        session = nil
        // Restore only our buffer change, and only if no other app changed it since.
        if let live = try? AudioDeviceManager.enumerate() {
            for record in originalBuffers {
                let original = record.device
                if let current = live.first(where: { $0.uid == original.uid }), current.bufferFrames == record.requested, current.bufferFrames != original.bufferFrames {
                    do { try AudioDeviceManager.setBuffer(original.bufferFrames, device: current) }
                    catch { errors.append("Buffer restore failed: \(error.localizedDescription)") }
                }
            }
        }
        originalBuffers.removeAll()
        Logger.audio.info("Routing stopped")
        for error in errors { Logger.audio.error("\(error, privacy: .public)") }
        return errors
    }
    func levels(micGain: Float, xboxDB: Float, headphoneDB: Float) {
        queue.async {
            guard let session = self.session else { return }
            DeckRouteSetLevels(session.outgoing!, micGain, xboxDB)
            DeckRouteSetLevels(session.incoming!, 1, headphoneDB)
        }
    }
    func mute(_ muted: Bool, outgoing: Bool) {
        queue.async {
            guard let session = self.session else { return }
            DeckRouteSetMuted(outgoing ? session.outgoing! : session.incoming!, muted)
        }
    }
    func startTone(expected: CalibrationContext, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            do {
                guard let session = self.session, DeckSafetyError(session.safety) == 0 else { throw AudioFailure("Routing must be running without errors before a test tone.") }
                let current = try AudioDeviceManager.enumerate()
                let resolved = try session.configuration.resolve(in: current)
                guard try CalibrationContext(configuration: session.configuration, devices: current) == expected,
                      zip(resolved, session.endpoints).allSatisfy({ $0.runtimeSignature == $1.runtimeSignature }) else {
                    throw AudioFailure("Devices changed since tone confirmation. Check the setup and confirm again.")
                }
                guard DeckRouteStartTone(session.outgoing!) else { throw AudioFailure("Tone requires an unmuted, primed Xbox route and no other active tone.") }
                self.toneWatchdog?.cancel()
                let toneID = UUID()
                self.toneID = toneID
                // A control-queue deadline backs up the callback's sample count
                // and continuous-clock deadline, including a stalled device.
                let deadline = DispatchWorkItem { [weak self, weak session] in
                    guard let self, let session, self.session === session, self.toneID == toneID else { return }
                    DeckRouteCancelTone(session.outgoing!)
                }
                self.toneWatchdog = deadline
                self.queue.asyncAfter(deadline: .now() + 2, execute: deadline)
                Logger.audio.info("Confirmed low-level calibration tone started (maximum two seconds)")
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
    func cancelTone() {
        queue.async {
            self.toneWatchdog?.cancel(); self.toneWatchdog = nil
            self.toneID = nil
            if let route = self.session?.outgoing { DeckRouteCancelTone(route) }
        }
    }
    func bypass() {
        queue.async { if let route = self.session?.outgoing { DeckRouteBypass(route) } }
    }
    func snapshot(completion: @escaping (RoutingSnapshot?) -> Void) {
        queue.async {
            let snapshot = self.session?.snapshot()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }
    func stopSynchronously() { queue.sync { _ = shutdown() } }
}
