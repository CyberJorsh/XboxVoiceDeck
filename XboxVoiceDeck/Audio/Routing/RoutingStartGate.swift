import Foundation

// Main-actor owned. Permission and engine completions must belong to the current
// request; sleep/stop invalidates both stages before queuing engine shutdown.
struct RoutingStartGate {
    private var request: UUID?

    mutating func begin() -> UUID {
        let token = UUID()
        request = token
        return token
    }

    func accepts(_ token: UUID) -> Bool { request == token }

    mutating func finish(_ token: UUID) -> Bool {
        guard accepts(token) else { return false }
        request = nil
        return true
    }

    mutating func cancel() { request = nil }
}
