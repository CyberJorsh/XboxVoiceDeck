import XCTest
import CoreAudio

final class DeckTests: XCTestCase {
    func route(xbox: Bool = true, inputRate: Double = 48000, outputRate: Double = 48000, channels: UInt32 = 1) throws -> OpaquePointer {
        try XCTUnwrap(DeckRouteCreate(inputRate, outputRate, 128, 128, channels, xbox))
    }
    func push(_ route: OpaquePointer, value: Float = 0.5, frames: Int = 128) {
        let data = [Float](repeating: value, count: frames)
        data.withUnsafeBufferPointer { DeckRoutePush(route, $0.baseAddress!, nil, UInt32(frames)) }
    }
    func pull(_ route: OpaquePointer, frames: Int = 128) -> [Float] {
        var result = [Float](repeating: -100, count: frames)
        result.withUnsafeMutableBufferPointer { DeckRoutePull(route, $0.baseAddress!, nil, UInt32(frames)) }
        return result
    }
    func pump(_ route: OpaquePointer, value: Float = 0.5, blocks: Int = 100) -> [Float] {
        var result: [Float] = []
        for _ in 0..<blocks { push(route, value: value); result = pull(route) }
        return result
    }
    func testRejectsUnsupportedFormatsAndDimensions() {
        XCTAssertNil(DeckRouteCreate(96000, 48000, 128, 128, 1, true))
        XCTAssertNil(DeckRouteCreate(48000, 48000, 0, 128, 1, true))
        XCTAssertNil(DeckRouteCreate(48000, 48000, 128, 128, 3, true))
    }
    func testStartsMutedAndPrimesWithoutUnderrun() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        XCTAssertTrue(pump(r).allSatisfy { $0 == 0 })
        XCTAssertEqual(DeckRouteSnapshot(r).underruns, 0)
        XCTAssertGreaterThan(DeckRouteSnapshot(r).inputRMS, 0)
    }
    func testExtremelyLowDefaultAndAbsoluteCeiling() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        DeckRouteSetGain(r, 1, -60, false)
        XCTAssertEqual(pump(r).last!, 0.0005, accuracy: 0.00002)
        DeckRouteSetGain(r, 4, 20, false) // Out-of-range requests cannot bypass protection.
        let output = pump(r, value: 5)
        XCTAssertLessThanOrEqual(output.map(abs).max()!, Float(0.95 * pow(10, -30.0 / 20)) + 0.000001)
        XCTAssertGreaterThan(DeckRouteSnapshot(r).limitedSamples, 0)
    }
    func testMuteIsImmediateAndBypassPreservesSafety() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        DeckRouteSetGain(r, 3, -60, false)
        _ = pump(r)
        DeckRouteSetGain(r, 3, -60, true)
        DeckRouteBypass(r)
        XCTAssertTrue(pull(r).allSatisfy { $0 == 0 })
        DeckRouteSetGain(r, 1, -60, false)
        XCTAssertEqual(pump(r).last!, 0.0005, accuracy: 0.00002)
    }
    func testRingWrapPreservesSignal() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        DeckRouteSetGain(r, 1, -60, false)
        XCTAssertEqual(pump(r, blocks: 1000).last!, 0.0005, accuracy: 0.00002)
        XCTAssertEqual(DeckRouteSnapshot(r).overruns, 0)
        XCTAssertEqual(DeckRouteSnapshot(r).underruns, 0)
    }
    func testOverflowDropsWholeIncomingBlock() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        push(r, frames: 16384)
        push(r, frames: 128)
        let s = DeckRouteSnapshot(r)
        XCTAssertEqual(s.overruns, 1)
        XCTAssertEqual(s.droppedFrames, 128)
    }
    func testUnderrunSilencesAndReprimes() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        DeckRouteSetGain(r, 1, -60, false)
        _ = pump(r)
        for _ in 0..<10 { _ = pull(r) }
        XCTAssertTrue(pull(r).allSatisfy { $0 == 0 })
        XCTAssertEqual(DeckRouteSnapshot(r).underruns, 1)
        XCTAssertEqual(DeckRouteSnapshot(r).resyncs, 1)
        XCTAssertEqual(pump(r).last!, 0.0005, accuracy: 0.00002)
    }
    func testHighWaterResyncBoundsLatency() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        _ = pump(r)
        push(r, frames: 3000)
        _ = pull(r)
        XCTAssertEqual(DeckRouteSnapshot(r).resyncs, 1)
        XCTAssertGreaterThan(DeckRouteSnapshot(r).droppedFrames, 2000)
        _ = pull(r)
        XCTAssertLessThan(DeckRouteSnapshot(r).bufferedFrames, 832)
    }
    func testNonFiniteSamplesCannotReachOutput() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        DeckRouteSetGain(r, 1, -60, false)
        XCTAssertTrue(pump(r, value: .nan).allSatisfy { $0 == 0 })
        XCTAssertTrue(pump(r, value: .infinity).allSatisfy { $0 == 0 })
    }
    func testStereoAndIndependentRouteIsolation() throws {
        let incoming = try route(xbox: false, channels: 2)
        let outgoing = try route()
        defer { DeckRouteDestroy(incoming); DeckRouteDestroy(outgoing) }
        DeckRouteSetGain(incoming, 1, -20, false)
        DeckRouteSetGain(outgoing, 1, -60, false)
        let left = [Float](repeating: 0.4, count: 128)
        let right = [Float](repeating: -0.2, count: 128)
        var outL = left, outR = right
        for _ in 0..<100 {
            left.withUnsafeBufferPointer { l in right.withUnsafeBufferPointer { r in DeckRoutePush(incoming, l.baseAddress!, r.baseAddress!, 128) } }
            outL.withUnsafeMutableBufferPointer { l in outR.withUnsafeMutableBufferPointer { r in DeckRoutePull(incoming, l.baseAddress!, r.baseAddress!, 128) } }
            push(outgoing, value: 0)
            XCTAssertTrue(pull(outgoing).allSatisfy { $0 == 0 })
        }
        XCTAssertEqual(outL.last!, 0.04, accuracy: 0.00002)
        XCTAssertEqual(outR.last!, -0.02, accuracy: 0.00002)
    }
    func testSafetyErrorLatchesFirstFailure() throws {
        let safety = try XCTUnwrap(DeckSafetyCreate()); defer { DeckSafetyDestroy(safety) }
        XCTAssertEqual(DeckSafetyError(safety), 0)
        DeckSafetyTrip(safety, -123)
        DeckSafetyTrip(safety, -456)
        XCTAssertEqual(DeckSafetyError(safety), -123)
    }
    func testCallbackOversizeFailsClosedWithoutWritingPastBuffer() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        let safety = try XCTUnwrap(DeckSafetyCreate()); defer { DeckSafetyDestroy(safety) }
        let context = try XCTUnwrap(DeckOutputCreate(r, safety, 1, 8)); defer { DeckOutputDestroy(context) }
        var samples = [Float](repeating: 0.5, count: 10)
        samples.withUnsafeMutableBufferPointer { values in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 8 * 4, mData: values.baseAddress))
            var flags: AudioUnitRenderActionFlags = []
            var time = AudioTimeStamp()
            XCTAssertEqual(DeckOutputCallback(UnsafeMutableRawPointer(context), &flags, &time, 0, 16, &buffers), 0)
        }
        XCTAssertEqual(DeckSafetyError(safety), kAudioUnitErr_TooManyFramesToProcess)
        XCTAssertTrue(samples.prefix(8).allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(samples.suffix(2)), [0.5, 0.5])
    }
    func testSharedSafetySilencesAnotherOutput() throws {
        let r = try route(); defer { DeckRouteDestroy(r) }
        let safety = try XCTUnwrap(DeckSafetyCreate()); defer { DeckSafetyDestroy(safety) }
        let context = try XCTUnwrap(DeckOutputCreate(r, safety, 1, 128)); defer { DeckOutputDestroy(context) }
        DeckRouteSetGain(r, 1, -60, false)
        _ = pump(r)
        DeckSafetyTrip(safety, -123)
        var samples = [Float](repeating: 1, count: 128)
        samples.withUnsafeMutableBufferPointer { values in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 128 * 4, mData: values.baseAddress))
            var flags: AudioUnitRenderActionFlags = []
            var time = AudioTimeStamp()
            XCTAssertEqual(DeckOutputCallback(UnsafeMutableRawPointer(context), &flags, &time, 0, 128, &buffers), 0)
            XCTAssertTrue(flags.contains(.unitRenderAction_OutputIsSilence))
        }
        XCTAssertTrue(samples.allSatisfy { $0 == 0 })
    }
    func endpoint(_ id: UInt32, uid: String, inputs: Int, outputs: Int, rate: Double = 48000) -> AudioEndpoint {
        AudioEndpoint(id: id, uid: uid, name: uid, manufacturer: "Test", inputChannels: inputs, outputChannels: outputs,
            sampleRate: rate, bufferFrames: 128, bufferRange: 32...512, supportedRates: "44100, 48000", alive: true,
            clockDomain: 0, inputLatency: 0, outputLatency: 0, inputSafety: 0, outputSafety: 0,
            inputStreamLatency: 0, outputStreamLatency: 0, inputSource: nil, outputSource: nil, inputJack: nil, outputJack: nil)
    }
    var configuration: RoutingConfiguration {
        RoutingConfiguration(headsetMicUID: "headset-in", headsetOutputUID: "headset-out", xboxInputUID: "usb", xboxOutputUID: "usb", xboxStereo: false)
    }
    var devices: [AudioEndpoint] {
        [endpoint(1, uid: "headset-in", inputs: 1, outputs: 0), endpoint(2, uid: "headset-out", inputs: 0, outputs: 2), endpoint(3, uid: "usb", inputs: 1, outputs: 2)]
    }
    func testSelectionResolvesUIDAfterDeviceIDChange() throws {
        var changed = devices
        changed[2] = endpoint(99, uid: "usb", inputs: 1, outputs: 2)
        XCTAssertEqual(try configuration.resolve(in: changed).map(\.id), [1, 2, 99, 99])
    }
    func testMissingDeviceNeverFallsBack() {
        XCTAssertThrowsError(try configuration.resolve(in: Array(devices.prefix(2))))
    }
    func testRejectsDuplicateInputsAndOutputs() {
        var c = configuration
        c.headsetMicUID = "usb"
        XCTAssertThrowsError(try c.resolve(in: devices))
        c = configuration; c.headsetOutputUID = "usb"
        XCTAssertThrowsError(try c.resolve(in: devices))
    }
    func testMonoCapabilitiesAndChannelBounds() {
        var c = configuration
        c.xboxStereo = true
        XCTAssertThrowsError(try c.resolve(in: devices))
        c.xboxStereo = false; c.micChannel = 1
        XCTAssertThrowsError(try c.resolve(in: devices))
    }
    func testConfigurationSerialization() throws {
        XCTAssertEqual(try JSONDecoder().decode(RoutingConfiguration.self, from: JSONEncoder().encode(configuration)), configuration)
        XCTAssertThrowsError(try JSONDecoder().decode(RoutingConfiguration.self, from: Data("{}".utf8)))
    }
}
