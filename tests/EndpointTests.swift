import XCTest
import AudioToolbox

final class EndpointKernelTests: XCTestCase {
    func testInputMetersAndClipsWithoutAnOutputRoute() throws {
        let test = try XCTUnwrap(DeckEndpointTestCreate(nil, true, false, 48000, 2, 0, 2, 128))
        defer { DeckEndpointTestDestroy(test) }
        let left: [Float] = [0.5, -0.5, 1, .nan]
        let right: [Float] = [0.25, -0.25, 0, 0]
        left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in DeckEndpointTestFeed(test, l.baseAddress, r.baseAddress, 4) } }
        let s = DeckEndpointTestRead(test)
        XCTAssertEqual(s.callbacks, 1); XCTAssertEqual(s.frames, 4); XCTAssertEqual(s.peak, 1)
        XCTAssertEqual(s.clips, 2); XCTAssertEqual(s.left, sqrt(1.5 / 4), accuracy: 0.00001)
        XCTAssertEqual(s.right, sqrt(0.125 / 4), accuracy: 0.00001)
        DeckEndpointTestCancel(test)
        left.withUnsafeBufferPointer { DeckEndpointTestFeed(test, $0.baseAddress, $0.baseAddress, 4) }
        XCTAssertEqual(DeckEndpointTestRead(test).callbacks, 1)
    }
    func testQuietOutputCeilingsStereoOrderAndAutomaticSilenceAtBothRates() throws {
        for rate in [44100.0, 48000.0] {
            for xbox in [false, true] {
                let test = try XCTUnwrap(DeckEndpointTestCreate(nil, false, xbox, rate, 2, 0, 2, 512))
                defer { DeckEndpointTestDestroy(test) }
                var l = [Float](repeating: 0, count: 512), r = l
                var position = 0; var heardLeft = false, heardRight = false
                while position < Int(rate * 2) + 512 {
                    l.withUnsafeMutableBufferPointer { a in r.withUnsafeMutableBufferPointer { b in DeckEndpointTestRender(test, a.baseAddress, b.baseAddress, 512) } }
                    for i in 0..<512 {
                        let p = position + i
                        XCTAssertLessThanOrEqual(abs(l[i]), xbox ? 0.000101 : 0.003163)
                        XCTAssertLessThanOrEqual(abs(r[i]), xbox ? 0.000101 : 0.003163)
                        if p >= Int(rate * 2) { XCTAssertEqual(l[i], 0); XCTAssertEqual(r[i], 0) }
                        else if xbox { XCTAssertEqual(l[i], r[i]) }
                        else if p < Int(rate) { XCTAssertEqual(r[i], 0); heardLeft = heardLeft || l[i] != 0 }
                        else { XCTAssertEqual(l[i], 0); heardRight = heardRight || r[i] != 0 }
                    }
                    position += 512
                }
                XCTAssertFalse(DeckEndpointTestRead(test).active)
                XCTAssertGreaterThan(DeckEndpointTestRead(test).peak, 0)
                if !xbox { XCTAssertTrue(heardLeft); XCTAssertTrue(heardRight) }
            }
        }
    }
    func testCancelledOutputIsSilentAndOversizedRenderDoesNotTouchBuffers() throws {
        let test = try XCTUnwrap(DeckEndpointTestCreate(nil, false, true, 48000, 1, 0, 1, 32))
        defer { DeckEndpointTestDestroy(test) }
        var samples = [Float](repeating: 9, count: 64)
        samples.withUnsafeMutableBufferPointer { DeckEndpointTestRender(test, $0.baseAddress, nil, 64) }
        XCTAssertTrue(samples.allSatisfy { $0 == 9 })
        XCTAssertNotEqual(DeckEndpointTestRead(test).error, 0)
        samples.withUnsafeMutableBufferPointer { DeckEndpointTestRender(test, $0.baseAddress, nil, 32) }
        XCTAssertTrue(samples.prefix(32).allSatisfy { $0 == 0 })
        XCTAssertTrue(samples.suffix(32).allSatisfy { $0 == 9 })
    }
    func testCancelledStartupCannotEmitItsFirstToneBuffer() throws {
        let safety = try XCTUnwrap(DeckSafetyCreate())
        let test = try XCTUnwrap(DeckEndpointTestCreate(nil, false, true, 48000, 1, 0, 1, 128))
        defer { DeckEndpointTestDestroy(test); DeckSafetyDestroy(safety) }
        DeckSafetyTrip(safety, -1)
        DeckEndpointTestSetSafety(test, safety)
        var samples = [Float](repeating: 1, count: 128)
        samples.withUnsafeMutableBufferPointer { DeckEndpointTestRender(test, $0.baseAddress, nil, 128) }
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
        XCTAssertFalse(DeckEndpointTestRead(test).active)
        XCTAssertEqual(DeckEndpointTestRead(test).callbacks, 0)
    }
    func testInvalidFormatAndChannelRangesAreRejected() {
        XCTAssertNil(DeckEndpointTestCreate(nil, true, false, 24000, 1, 0, 1, 128))
        XCTAssertNil(DeckEndpointTestCreate(nil, true, false, 48000, 1, 0, 2, 128))
        XCTAssertNil(DeckEndpointTestCreate(nil, true, false, 48000, 2, .max, 1, 128))
        XCTAssertNil(DeckEndpointTestCreate(nil, false, true, 48000, 2, 0, 2, 8192))
    }
}

@MainActor
final class EndpointModelTests: XCTestCase {
    private func request(_ role: EndpointRole = .headsetMic) throws -> EndpointTestRequest {
        try EndpointTestRequest(role: role, configuration: UITestFixture.configuration, devices: UITestFixture.endpoints)
    }
    func testOneEndpointCanBeTestedWithOtherSelectionsMissingAndMonoXboxInput() throws {
        let device = UITestFixture.endpoints[0]
        let config = RoutingConfiguration(xboxInputUID: device.uid)
        let request = try EndpointTestRequest(role: .xboxInput, configuration: config, devices: [device])
        XCTAssertEqual(request.measuredChannels, 1)
        XCTAssertThrowsError(try config.resolve(in: [device]))
        XCTAssertThrowsError(try request.validateLive([]))
    }
    func testLateStartAndSnapshotCannotRestoreCancelledSession() throws {
        let engine = MockEndpointTester()
        let model = EndpointTestModel(engine: engine, now: { 0 })
        model.start(try request()); model.start(try request(.xboxInput))
        XCTAssertEqual(engine.starts.count, 1)
        model.stop(); engine.starts[0](.success(()))
        XCTAssertFalse(model.busy)
        model.start(try request()); engine.starts[1](.success(()))
        model.poll(); model.stop()
        var old = DeckEndpointTestSnapshot(); old.active = true; old.peak = 0.9
        engine.snapshots[0](old)
        XCTAssertFalse(model.busy); XCTAssertEqual(model.reading.peak, 0)
    }
    func testRevocationAndSelectionChangesStopOnlyTheTest() throws {
        for permission in [true, false] {
            let engine = MockEndpointTester(); let model = EndpointTestModel(engine: engine, now: { 0 })
            model.start(try request()); engine.starts[0](.success(()))
            model.validate(devices: permission ? [] : UITestFixture.endpoints, configuration: UITestFixture.configuration, captureAllowed: permission)
            XCTAssertFalse(model.busy); XCTAssertEqual(engine.stopCount, 1)
        }
    }
    func testStallErrorAndNoCallbackCompletionAreNeverReportedAsSuccess() throws {
        for kind in 0..<3 {
            let engine = MockEndpointTester(); var now: TimeInterval = 0
            let model = EndpointTestModel(engine: engine, now: { now })
            model.start(try request()); engine.starts[0](.success(()))
            now = 3; model.poll()
            var value = DeckEndpointTestSnapshot(); value.active = kind == 0; value.error = kind == 1 ? -50 : 0
            engine.snapshots[0](value)
            XCTAssertFalse(model.busy); XCTAssertTrue(model.message.contains("AUDIO ERROR"))
        }
    }
    func testSuccessfulCompletionPreservesMeasuredPeakAndReportsShutdownFailure() throws {
        let engine = MockEndpointTester(); let model = EndpointTestModel(engine: engine, now: { 0 })
        model.start(try request()); engine.starts[0](.success(())); model.poll()
        var value = DeckEndpointTestSnapshot(); value.callbacks = 12; value.peak = 0.3
        engine.snapshots[0](value)
        XCTAssertFalse(model.busy); XCTAssertEqual(model.reading.peak, 0.3)
        XCTAssertTrue(model.message.contains("Test finished"))
        engine.stopErrors = ["dispose failed"]
        model.start(try request()); model.stop()
        XCTAssertTrue(model.message.contains("dispose failed"))
    }
}

final class MockEndpointTester: EndpointTesting {
    var starts: [(Result<Void, Error>) -> Void] = []
    var snapshots: [(DeckEndpointTestSnapshot?) -> Void] = []
    var requests: [EndpointTestRequest] = []
    var stopCount = 0
    var stopErrors: [String] = []
    func start(_ request: EndpointTestRequest, completion: @escaping (Result<Void, Error>) -> Void) { requests.append(request); starts.append(completion) }
    func stop(completion: @escaping ([String]) -> Void) { stopCount += 1; completion(stopErrors) }
    func snapshot(completion: @escaping (DeckEndpointTestSnapshot?) -> Void) { snapshots.append(completion) }
    func stopSynchronously() { stopCount += 1 }
}
