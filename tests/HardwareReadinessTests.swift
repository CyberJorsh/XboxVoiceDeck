import XCTest

final class HardwareReadinessTests: XCTestCase {
    func testDelayedBufferAcknowledgementSucceedsAndRemovesListener() throws {
        var notification: (() -> Void)?
        var installed = false, removed = false, reads = 0
        try BufferChange.waitForValue(128, read: {
            reads += 1
            if reads == 1 {
                // The first read remains stale. The event is delivered by an
                // independent queue, just as a delayed HAL notification is.
                let signal = notification!
                DispatchQueue.global().async { signal() }
                return 512
            }
            return 128
        }, write: { XCTAssertTrue(installed) }, subscribe: {
            installed = true; notification = $0
            return { removed = true }
        })
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(removed)
    }

    func testNotificationDuringWriteIsNotLost() throws {
        var notification: (() -> Void)?
        var reads = 0
        try BufferChange.waitForValue(64, read: { reads += 1; return reads == 1 ? 512 : 64 },
            write: { notification?() }, subscribe: { notification = $0; return {} })
        XCTAssertEqual(reads, 2)
    }

    func testUnacknowledgedBufferChangeTimesOutWithoutClaimingSuccess() {
        var removed = false
        XCTAssertThrowsError(try BufferChange.waitForValue(128, timeout: 0.001,
            read: { 512 }, write: {}, subscribe: { _ in { removed = true } })) {
            XCTAssertTrue($0.localizedDescription.contains("driver may still apply"))
        }
        XCTAssertTrue(removed)
    }

    func testBufferWriteFailureCleansUpListener() {
        var removed = false
        XCTAssertThrowsError(try BufferChange.waitForValue(128,
            read: { XCTFail("Failed write must not proceed"); return 128 },
            write: { throw AudioFailure("Write rejected") }, subscribe: { _ in { removed = true } })) {
                XCTAssertEqual($0.localizedDescription, "Write rejected")
            }
        XCTAssertTrue(removed)
    }

    func testForcedRollbackNeedsANotificationEvenIfOldValueStillReadsBack() {
        XCTAssertThrowsError(try BufferChange.waitForValue(512, timeout: 0.001,
            read: { 512 }, write: {}, subscribe: { _ in {} }, requireNotification: true))
    }

    func testBrokenUnselectedDeviceDoesNotDiscardHealthyDevices() throws {
        let devices = UITestFixture.endpoints
        let inventory = AudioDeviceManager.inspect(ids: [devices[0].id, 9999, devices[1].id]) { id in
            guard let device = devices.first(where: { $0.id == id }) else { throw AudioFailure("Disconnected during channel read") }
            return device
        }
        XCTAssertEqual(Set(inventory.devices.map(\.uid)), Set(devices.map(\.uid)))
        XCTAssertEqual(inventory.issues.count, 1)
        XCTAssertTrue(inventory.issues[0].contains("9999"))
        XCTAssertNoThrow(try UITestFixture.configuration.resolve(in: inventory.devices))
    }

    func testBrokenSelectedDeviceStillBlocksExplicitRouting() {
        let device = UITestFixture.endpoints[0]
        let inventory = AudioDeviceManager.inspect(ids: [device.id, 9999]) { id in
            guard id == device.id else { throw AudioFailure("USB missing") }; return device
        }
        XCTAssertThrowsError(try UITestFixture.configuration.resolve(in: inventory.devices))
    }

    func testDefaultAndAlertOutputCollisionsAreFlaggedWithoutBlockingMutedTests() {
        for alert in [false, true] {
            let id = UITestFixture.endpoints[1].id
            let preflight = RoutingPreflight(configuration: UITestFixture.configuration, devices: UITestFixture.endpoints,
                permission: .authorized, defaultOutput: alert ? nil : id, alertOutput: alert ? id : nil)
            XCTAssertEqual(preflight.checks.first { $0.id == "system-output" }?.status, .reportedProblem)
            XCTAssertTrue(preflight.canStartMuted)
        }
    }

    func testNoDefaultCollisionDoesNotCertifyOtherAppsOrElectricalSafety() {
        let preflight = RoutingPreflight(configuration: UITestFixture.configuration, devices: UITestFixture.endpoints,
            permission: .authorized, defaultOutput: 123, alertOutput: 123)
        XCTAssertEqual(preflight.checks.first { $0.id == "system-output" }?.status, .manualRequired)
    }

    func test512FrameBufferWarnsAboutLatencyBut128DoesNot() {
        var configuration = UITestFixture.configuration
        configuration.requestedBuffer = 512
        let slow = RoutingPreflight(configuration: configuration, devices: UITestFixture.endpoints, permission: .authorized)
        XCTAssertTrue(slow.checks.first { $0.id == "latency" }?.detail.contains("54.7") == true)
        configuration.requestedBuffer = 128
        XCTAssertFalse(RoutingPreflight(configuration: configuration, devices: UITestFixture.endpoints,
            permission: .authorized).checks.contains { $0.id == "latency" })
    }
}

final class RoutingControlGateTests: XCTestCase {
    private func withRoutes(_ body: (RoutingControlGate, OpaquePointer, OpaquePointer, OpaquePointer) throws -> Void) throws {
        let outgoing = try XCTUnwrap(DeckRouteCreate(48000, 48000, 128, 128, 1, true))
        let incoming = try XCTUnwrap(DeckRouteCreate(48000, 48000, 128, 128, 1, false))
        let safety = try XCTUnwrap(DeckSafetyCreate())
        let gate = RoutingControlGate()
        defer { gate.detach(); DeckRouteDestroy(outgoing); DeckRouteDestroy(incoming); DeckSafetyDestroy(safety) }
        XCTAssertTrue(gate.attach(outgoing: outgoing, incoming: incoming, safety: safety, token: gate.token()))
        try body(gate, outgoing, incoming, safety)
    }
    private func prime(_ route: OpaquePointer) {
        let input = [Float](repeating: 0.1, count: 128)
        var output = [Float](repeating: 0, count: 128)
        for _ in 0..<30 {
            input.withUnsafeBufferPointer { DeckRoutePush(route, $0.baseAddress, nil, 128) }
            output.withUnsafeMutableBufferPointer { DeckRoutePull(route, $0.baseAddress, nil, 128) }
        }
    }
    func testSafetyCommandsDoNotWaitForBlockedControlQueue() throws {
        let blocked = DispatchQueue(label: "test.blocked-driver")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        blocked.async { entered.signal(); release.wait() }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        defer { release.signal() }
        try withRoutes { gate, outgoing, incoming, safety in
            let engine = AudioRoutingEngine(queue: blocked, controls: gate)
            engine.mute(false, outgoing: true); engine.mute(false, outgoing: false)
            engine.mute(true, outgoing: true)
            XCTAssertTrue(DeckRouteSnapshot(outgoing).muted)
            XCTAssertFalse(DeckRouteSnapshot(incoming).muted)
            engine.stop()
            XCTAssertTrue(DeckRouteSnapshot(incoming).muted)
            XCTAssertNotEqual(DeckSafetyError(safety), 0)
            gate.mute(false, outgoing: true)
            XCTAssertTrue(DeckRouteSnapshot(outgoing).muted, "A stopped session cannot be reopened by a late unmute")
        }
    }
    func testStopInvalidatesUnpublishedStartupAndDetachedPointers() throws {
        try withRoutes { gate, outgoing, incoming, safety in
            let stale = gate.token()
            gate.stop(); gate.detach()
            XCTAssertFalse(gate.attach(outgoing: outgoing, incoming: incoming, safety: safety, token: stale))
            gate.mute(false, outgoing: true); gate.levels(micGain: 4, xboxDB: -30, headphoneDB: 0)
            XCTAssertTrue(DeckRouteSnapshot(outgoing).muted)
        }
    }
    func testCancelAndMuteRejectQueuedToneEvenAfterExplicitUnmute() throws {
        try withRoutes { gate, outgoing, _, _ in
            gate.mute(false, outgoing: true); prime(outgoing)
            let cancelled = gate.toneToken()
            gate.cancelTone()
            XCTAssertFalse(gate.startTone(token: cancelled))
            let muted = gate.toneToken()
            gate.mute(true, outgoing: true); gate.mute(false, outgoing: true)
            XCTAssertFalse(gate.startTone(token: muted))
            XCTAssertTrue(gate.startTone(token: gate.toneToken()), "Fresh confirmed tone still works")
            gate.cancelTone(bypass: true)
            XCTAssertFalse(DeckRouteSnapshot(outgoing).toneActive)
            XCTAssertTrue(DeckRouteSnapshot(outgoing).muted)
        }
    }
}
