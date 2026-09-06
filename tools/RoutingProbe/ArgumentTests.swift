import Foundation

// Pure argument/configuration checks: no HAL, microphone, permissions or devices.
func runRoutingProbeArgumentTests() throws {
    var passed = 0
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AudioFailure("Probe parser self-test failed: \(message)") }
        passed += 1
    }
    func rejected(_ args: [String]) throws {
        do { _ = try RoutingProbeArguments(args) }
        catch { passed += 1; return }
        throw AudioFailure("Unsafe/invalid arguments unexpectedly accepted: \(args)")
    }
    let check = try RoutingProbeArguments(["--config", "test.json", "--check"])
    try require(check.checkOnly, "check mode must not capture")
    let run = try RoutingProbeArguments(["--config", "test.json", "--allow-capture", "--duration", "60"])
    try require(!run.checkOnly && run.duration == 60, "bounded explicit capture mode")
    for args in [[], ["--config", "a"], ["--config", "a", "--allow-capture", "--check"],
                 ["--config", "a", "--check", "--duration", "5"], ["--config", "a", "--check", "--check"],
                 ["--config", "a", "--allow-capture", "--duration", "61"],
                 ["--config", "a", "--allow-capture", "--duration", "nan"],
                 ["--config", "a", "--allow-capture", "--duration", "inf"],
                 ["--config", "a", "--allow-capture", "--duration", "1"],
                 ["--config", "a", "--report", "--allow-capture"], ["--config", "a", "--unknown"]] {
        try rejected(args)
    }
    var config = RoutingConfiguration()
    config.headsetMicUID = "headset-in"; config.headsetOutputUID = "headset-out"
    config.xboxInputUID = "usb-in"; config.xboxOutputUID = "usb-out"
    let decoded = try RoutingProbeArguments.decodeConfiguration(JSONEncoder().encode(config))
    try require(decoded == config, "configuration round-trip")
    struct ReadinessEnvelope: Encodable { let schemaVersion: Int; let configuration: RoutingConfiguration }
    let envelope = try JSONEncoder().encode(ReadinessEnvelope(schemaVersion: 1, configuration: config))
    let imported = try RoutingProbeArguments.decodeConfiguration(envelope)
    try require(imported == config, "readiness report preserves explicit configuration")
    var futureRejected = false
    let future = try JSONEncoder().encode(ReadinessEnvelope(schemaVersion: 2, configuration: config))
    do { _ = try RoutingProbeArguments.decodeConfiguration(future) }
    catch { futureRejected = true }
    try require(futureRejected, "future readiness schemas are rejected")
    for invalid in 0..<4 {
        var bad = config
        switch invalid {
        case 0: bad.requestedBuffer = 1
        case 1: bad.micChannel = -1
        case 2: bad.xboxFirstChannel = 31
        default: bad.headsetMicUID = "   "
        }
        do { _ = try RoutingProbeArguments.decodeConfiguration(JSONEncoder().encode(bad)) }
        catch { passed += 1; continue }
        throw AudioFailure("Invalid probe configuration accepted: \(invalid)")
    }
    var primed = DeckSnapshot()
    primed.droppedFrames = 96; primed.primingDroppedFrames = 96
    try require(!RoutingProbeValidation.hasUnexpectedBufferEvents(primed), "priming-only discards are allowed")
    primed.droppedFrames = 0
    try require(!RoutingProbeValidation.hasUnexpectedBufferEvents(primed), "newer priming classification with an older total is allowed")
    primed.droppedFrames = 97
    try require(RoutingProbeValidation.hasUnexpectedBufferEvents(primed), "non-priming dropped frames must fail")
    for event in 0..<3 {
        var fault = DeckSnapshot()
        if event == 0 { fault.underruns = 1 }
        if event == 1 { fault.overruns = 1 }
        if event == 2 { fault.resyncs = 1 }
        try require(RoutingProbeValidation.hasUnexpectedBufferEvents(fault), "buffer fault \(event) must fail")
    }
    print("PASS: \(passed) routing-probe parser/configuration/stability checks. No hardware opened.")
}
