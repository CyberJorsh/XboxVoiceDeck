import Foundation
import AudioToolbox
import OSLog

enum EndpointRole: String, CaseIterable {
    case headsetMic, headsetOutput, xboxInput, xboxOutput
    var input: Bool { self == .headsetMic || self == .xboxInput }
    var index: Int { Self.allCases.firstIndex(of: self)! }
    var title: String {
        ["Headset microphone", "Headset output", "Xbox audio input", "Xbox mic output"][index]
    }
}

struct EndpointTestRequest: Equatable {
    let role: EndpointRole
    let device: AudioEndpoint
    let firstChannel: Int
    let measuredChannels: Int

    init(role: EndpointRole, configuration: RoutingConfiguration, devices: [AudioEndpoint]) throws {
        let uid = configuration.selectedUIDs[role.index]
        guard !uid.isEmpty, let device = devices.first(where: { $0.uid == uid }) else {
            throw AudioFailure("Select an available device for \(role.title) first.")
        }
        let channels = role.input ? device.inputChannels : device.outputChannels
        let first = role == .headsetMic ? configuration.micChannel : role == .xboxInput ? configuration.xboxFirstChannel : 0
        guard device.supported, channels > 0, channels <= 32, device.bufferFrames > 0, device.bufferFrames <= 4096,
              first >= 0, first < channels else { throw AudioFailure("Unsupported or missing endpoint/channel. Tests require 44.1/48 kHz and an available channel.") }
        self.role = role; self.device = device; self.firstChannel = first
        // A mono adapter can be diagnosed before the full routing setup is valid.
        self.measuredChannels = role == .headsetMic ? 1 : min(2, channels - first)
    }
    func validateLive(_ devices: [AudioEndpoint]) throws {
        guard devices.contains(where: { $0.uid == device.uid && $0.runtimeSignature == device.runtimeSignature }) else {
            throw AudioFailure("The selected device changed since the test was requested. Select it again and retry.")
        }
    }
}

protocol EndpointTesting: AnyObject {
    func start(_ request: EndpointTestRequest, completion: @escaping (Result<Void, Error>) -> Void)
    func stop(completion: @escaping ([String]) -> Void)
    func snapshot(completion: @escaping (DeckEndpointTestSnapshot?) -> Void)
    func stopSynchronously()
}

private final class EndpointTestCancellation {
    let safety: OpaquePointer
    init() throws {
        guard let safety = DeckSafetyCreate() else { throw AudioFailure("Cannot allocate endpoint cancellation state.") }
        self.safety = safety
    }
    var cancelled: Bool { DeckSafetyError(safety) != 0 }
    func cancel() { DeckSafetyTrip(safety, -1) }
    deinit { DeckSafetyDestroy(safety) }
}

private final class EndpointTestSession {
    let unit: HALUnit
    let context: OpaquePointer
    let cancellation: EndpointTestCancellation
    private var closed = false

    init(_ request: EndpointTestRequest, cancellation: EndpointTestCancellation) throws {
        self.cancellation = cancellation
        unit = try HALUnit(device: request.device, capture: request.role.input)
        guard let context = DeckEndpointTestCreate(unit.unit, request.role.input, request.role == .xboxOutput,
            unit.rate, unit.channels, UInt32(request.firstChannel), UInt32(request.measuredChannels), unit.maxFrames) else {
            throw AudioFailure("Cannot allocate lock-free endpoint test buffers.")
        }
        self.context = context
        DeckEndpointTestSetSafety(context, cancellation.safety)
        do {
            try unit.attach(callback: DeckEndpointTestCallback(context))
            guard !cancellation.cancelled else { throw AudioFailure("Endpoint test startup cancelled.") }
            try unit.start()
        } catch {
            let errors = close()
            throw AudioFailure(([error.localizedDescription] + errors).joined(separator: "\n"))
        }
    }
    func close() -> [String] {
        guard !closed else { return [] }; closed = true
        cancellation.cancel()
        DeckEndpointTestCancel(context)
        let status = unit.close()
        if unit.disposed { DeckEndpointTestDestroy(context) }
        // On HAL disposal failure, retain the silenced context to prevent UAF.
        if !unit.disposed {
            // The quarantined C callback can still read its cancellation flag.
            _ = Unmanaged.passRetained(cancellation)
            return ["Endpoint test disposal failed (\(status)); silenced memory retained. Quit and reopen the app."]
        }
        return status == noErr ? [] : ["Endpoint test shutdown: Core Audio error \(status)"]
    }
    deinit { for error in close() { Logger.audio.error("\(error, privacy: .public)") } }
}

final class EndpointTestEngine: EndpointTesting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "XboxVoiceDeck.endpoint-test", qos: .userInitiated)
    private var session: EndpointTestSession?
    private var finalSnapshot: DeckEndpointTestSnapshot?
    private var watchdog: DispatchWorkItem?
    // Control-thread lock only, never held across HAL calls or used by callbacks.
    private let commandLock = NSLock()
    private var cancellation: EndpointTestCancellation?

    func start(_ request: EndpointTestRequest, completion: @escaping (Result<Void, Error>) -> Void) {
        let cancellation: EndpointTestCancellation
        do { cancellation = try EndpointTestCancellation() }
        catch { DispatchQueue.main.async { completion(.failure(error)) }; return }
        commandLock.lock()
        self.cancellation?.cancel(); self.cancellation = cancellation
        commandLock.unlock()
        queue.async { [self] in
            do {
                let errors = self.shutdown()
                guard errors.isEmpty else { throw AudioFailure(errors.joined(separator: "\n")) }
                self.finalSnapshot = nil
                guard !cancellation.cancelled else { throw AudioFailure("Endpoint test startup cancelled.") }
                try request.validateLive(AudioDeviceManager.enumerate())
                let session = try EndpointTestSession(request, cancellation: cancellation)
                self.session = session
                let watchdog = DispatchWorkItem { [weak self, weak session] in
                    guard let self, let session, self.session === session else { return }
                    _ = self.shutdown()
                }
                self.watchdog = watchdog
                self.queue.asyncAfter(deadline: .now() + (request.role.input ? 10 : 2), execute: watchdog)
                Logger.audio.info("Endpoint test started: \(request.role.rawValue, privacy: .public), device ID \(request.device.id)")
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                let errors = self.shutdown()
                let failure = AudioFailure(([error.localizedDescription] + errors).joined(separator: "\n"))
                DispatchQueue.main.async { completion(.failure(failure)) }
            }
        }
    }
    private func shutdown() -> [String] {
        watchdog?.cancel(); watchdog = nil
        guard let session else { return [] }
        DeckEndpointTestCancel(session.context)
        var snapshot = DeckEndpointTestRead(session.context)
        let errors = session.close()
        self.session = nil
        if !errors.isEmpty { snapshot.error = -1 }
        self.finalSnapshot = snapshot
        for error in errors { Logger.audio.error("\(error, privacy: .public)") }
        Logger.audio.info("Endpoint test stopped; callbacks \(snapshot.callbacks)")
        return errors
    }
    func stop(completion: @escaping ([String]) -> Void) {
        cancelImmediately()
        queue.async { let errors = self.shutdown(); DispatchQueue.main.async { completion(errors) } }
    }
    func snapshot(completion: @escaping (DeckEndpointTestSnapshot?) -> Void) {
        queue.async {
            let snapshot = self.session.map { DeckEndpointTestRead($0.context) } ?? self.finalSnapshot
            DispatchQueue.main.async { completion(snapshot) }
        }
    }
    private func cancelImmediately() {
        commandLock.lock(); cancellation?.cancel(); commandLock.unlock()
    }
    func stopSynchronously() { cancelImmediately(); queue.sync { _ = shutdown() } }
}
