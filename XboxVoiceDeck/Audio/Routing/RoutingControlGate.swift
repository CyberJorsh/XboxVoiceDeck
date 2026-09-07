import Foundation

// This lock protects pointer lifetime only. No HAL call, dispatch wait, callback,
// or allocation runs while held. Realtime code reads the C atomics without locks.
final class RoutingControlGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var toneGeneration: UInt64 = 0
    private var routes: (outgoing: OpaquePointer, incoming: OpaquePointer, safety: OpaquePointer)?

    func token() -> UInt64 { lock.lock(); defer { lock.unlock() }; return generation }
    func toneToken() -> UInt64 { lock.lock(); defer { lock.unlock() }; return toneGeneration }
    func accepts(_ token: UInt64) -> Bool { lock.lock(); defer { lock.unlock() }; return generation == token }

    func attach(outgoing: OpaquePointer, incoming: OpaquePointer, safety: OpaquePointer, token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == token else { return false }
        routes = (outgoing, incoming, safety)
        return true
    }
    // Detach before disposing units or freeing routes, after silencing callbacks.
    func detach() { lock.lock(); defer { lock.unlock() }; routes = nil }
    func begin() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; toneGeneration &+= 1
        guard let routes else { return generation }
        DeckRouteSetMuted(routes.outgoing, true)
        DeckRouteSetMuted(routes.incoming, true)
        DeckSafetyTrip(routes.safety, -1)
        return generation
    }
    func stop() { _ = begin() }
    func mute(_ muted: Bool, outgoing: Bool) {
        lock.lock(); defer { lock.unlock() }
        if muted && outgoing { toneGeneration &+= 1 }
        guard let routes, DeckSafetyError(routes.safety) == 0 else { return }
        DeckRouteSetMuted(outgoing ? routes.outgoing : routes.incoming, muted)
    }
    func levels(micGain: Float, xboxDB: Float, headphoneDB: Float) {
        lock.lock(); defer { lock.unlock() }
        guard let routes else { return }
        DeckRouteSetLevels(routes.outgoing, micGain, xboxDB)
        DeckRouteSetLevels(routes.incoming, 1, headphoneDB)
    }
    func startTone(token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard toneGeneration == token, let routes, DeckSafetyError(routes.safety) == 0 else { return false }
        return DeckRouteStartTone(routes.outgoing)
    }
    func cancelTone(bypass: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        toneGeneration &+= 1
        guard let routes else { return }
        if bypass { DeckRouteBypass(routes.outgoing) } else { DeckRouteCancelTone(routes.outgoing) }
    }
}
