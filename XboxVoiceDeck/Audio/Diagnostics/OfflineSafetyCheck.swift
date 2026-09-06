import Foundation

struct OfflineSafetyResult {
    let checks: [String]
    let passed: Bool
    var summary: String {
        ([passed ? "Software checks passed — hardware remains unverified." : "SOFTWARE CHECK FAILED",
          "Synthetic samples through the real route kernel. No Audio Units, audio devices or recordings."] + checks).joined(separator: "\n")
    }
}

enum OfflineSafetyCheck {
    static func run() -> OfflineSafetyResult {
        guard let outgoing = DeckRouteCreate(48000, 48000, 128, 128, 1, true) else {
            return OfflineSafetyResult(checks: ["Route allocation failed."], passed: false)
        }
        defer { DeckRouteDestroy(outgoing) }
        guard let incoming = DeckRouteCreate(48000, 48000, 128, 128, 2, false) else {
            return OfflineSafetyResult(checks: ["Incoming route allocation failed."], passed: false)
        }
        defer { DeckRouteDestroy(incoming) }
        var checks: [String] = []
        var passed = true
        func record(_ condition: Bool, _ label: String) {
            passed = passed && condition
            checks.append("\(condition ? "PASS" : "FAIL") · \(label)")
        }
        let silence = [Float](repeating: 0, count: 128)
        let overload = [Float](repeating: 4, count: 128)
        let game = [Float](repeating: 0.25, count: 128)
        var left = silence, right = silence
        func step(_ route: OpaquePointer, _ input: [Float]) -> Float {
            input.withUnsafeBufferPointer { DeckRoutePush(route, $0.baseAddress!, nil, 128) }
            left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in DeckRoutePull(route, l.baseAddress!, r.baseAddress!, 128) } }
            return left.map(abs).max() ?? 0
        }
        var peak: Float = 0
        for _ in 0..<100 { peak = max(peak, step(outgoing, overload)) }
        record(peak == 0, "Muted startup stays silent under overload")
        DeckRouteSetMuted(outgoing, false)
        peak = 0
        for _ in 0..<100 { peak = max(peak, step(outgoing, overload)) }
        record(peak <= 0.000951 && DeckRouteSnapshot(outgoing).limiterReductionDB > 1,
               String(format: "Limiter contains overload; output peak %.6f FS", peak))
        for _ in 0..<100 { _ = step(outgoing, silence) }
        DeckRouteSetGain(incoming, 1, -20, false)
        peak = 0
        for _ in 0..<100 { _ = step(incoming, game); peak = max(peak, step(outgoing, silence)) }
        record(peak == 0 && DeckRouteSnapshot(incoming).outputRMS > 0, "Xbox incoming signal is isolated from outgoing mic")
        let started = DeckRouteStartTone(outgoing)
        peak = 0
        for _ in 0..<800 { peak = max(peak, step(outgoing, silence)) }
        let tone = DeckRouteSnapshot(outgoing)
        record(started && tone.toneFrames == 96000 && !tone.toneActive && tone.muted && peak > 0 && peak <= 0.0000317,
               "Two-second tone is bounded below −90 dBFS and automatically mutes")
        DeckRouteSetLevels(outgoing, 4, -30)
        record(step(outgoing, overload) == 0, "Level changes cannot undo tone completion mute")
        DeckRouteSetMuted(outgoing, false)
        let restarted = DeckRouteStartTone(outgoing)
        DeckRouteBypass(outgoing)
        record(restarted && step(outgoing, overload) == 0 && !DeckRouteSnapshot(outgoing).toneActive,
               "Bypass cancels tone and keeps output silent")
        return OfflineSafetyResult(checks: checks, passed: passed)
    }
}
