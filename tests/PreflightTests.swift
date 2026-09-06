import XCTest
import AVFoundation

final class PreflightTests: XCTestCase {
    private var configuration: RoutingConfiguration { UITestFixture.configuration }
    private var devices: [AudioEndpoint] { UITestFixture.endpoints }
    private func usb(inputs: Int = 2, rate: Double = 48000, range: ClosedRange<UInt32>? = 32...512) -> AudioEndpoint {
        AudioEndpoint(id: 9002, uid: "fixture.xbox", name: "SIMULATED USB", manufacturer: "test",
            inputChannels: inputs, outputChannels: 2, sampleRate: rate, bufferFrames: 128, bufferRange: range,
            supportedRates: "44100, 48000", alive: true, clockDomain: 0, inputLatency: 0, outputLatency: 0,
            inputSafety: 0, outputSafety: 0, inputStreamLatency: 0, outputStreamLatency: 0,
            inputSource: nil, outputSource: nil, inputJack: nil, outputJack: nil)
    }
    func testMissingRolesAreIndividuallyActionable() {
        let p = RoutingPreflight(configuration: RoutingConfiguration(), devices: [], permission: .authorized)
        XCTAssertFalse(p.canStartMuted)
        XCTAssertEqual(p.checks.filter { $0.id.hasPrefix("endpoint-") && $0.status == .blocked }.count, 4)
        XCTAssertTrue(p.checks[0].detail.contains("Select"))
    }
    func testReadySoftwareNeverPassesPhysicalAcceptance() {
        let p = RoutingPreflight(configuration: configuration, devices: devices, permission: .authorized)
        XCTAssertTrue(p.canStartMuted)
        XCTAssertEqual(p.checks.first { $0.id == "electrical" }?.status, .pending)
        XCTAssertEqual(p.checks.first { $0.id == "boom" }?.status, .pending)
    }
    func testMonoInputRequiresExplicitMonoSelection() {
        let mono = [devices[0], usb(inputs: 1)]
        XCTAssertFalse(RoutingPreflight(configuration: configuration, devices: mono, permission: .authorized).canStartMuted)
        var c = configuration; c.xboxStereo = false
        XCTAssertTrue(RoutingPreflight(configuration: c, devices: mono, permission: .authorized).canStartMuted)
    }
    func testUnsupportedRateBlocksStart() {
        let p = RoutingPreflight(configuration: configuration, devices: [devices[0], usb(rate: 96000)], permission: .authorized)
        XCTAssertFalse(p.canStartMuted)
        XCTAssertEqual(p.checks.first { $0.id == "endpoint-2" }?.status, .blocked)
    }
    func testBufferRangeAllowsCurrentAndKeepButRejectsUnreportedChange() {
        let d = [devices[0], usb(range: nil)]
        var c = configuration
        XCTAssertTrue(RoutingPreflight(configuration: c, devices: d, permission: .authorized).canStartMuted)
        c.requestedBuffer = 64
        XCTAssertFalse(RoutingPreflight(configuration: c, devices: d, permission: .authorized).canStartMuted)
        XCTAssertThrowsError(try c.resolve(in: d), "Startup must reject the same blocked buffer before opening devices")
        c.requestedBuffer = 96
        XCTAssertThrowsError(try c.resolve(in: devices), "A saved value outside the offered sizes must be rejected")
        c.requestedBuffer = 0
        XCTAssertTrue(RoutingPreflight(configuration: c, devices: d, permission: .authorized).canStartMuted)
    }
    func testPermissionCanBeRequestedButDenialBlocksPreflight() {
        XCTAssertTrue(RoutingPreflight(configuration: configuration, devices: devices, permission: .notDetermined).canStartMuted)
        XCTAssertFalse(RoutingPreflight(configuration: configuration, devices: devices, permission: .denied).canStartMuted)
        XCTAssertFalse(RoutingPreflight(configuration: configuration, devices: devices, permission: .restricted).canStartMuted)
    }
    func testReadinessReportRoundTripPreservesEvidenceBoundaries() throws {
        var snapshot = RoutingSnapshot()
        snapshot.outgoing.underruns = 2; snapshot.incoming.outputCallbacks = 400
        let report = ReadinessReport(configuration: configuration, devices: devices,
            preflight: RoutingPreflight(configuration: configuration, devices: devices, permission: .authorized),
            snapshot: snapshot, running: false, status: "SIMULATED", simulated: true,
            observations: ["boomMic": "observed working"], date: Date(timeIntervalSince1970: 1000))
        let data = try report.encoded()
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ReadinessReport.self, from: data)
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertTrue(decoded.simulated)
        XCTAssertEqual(decoded.physicalAcceptance, "pending")
        XCTAssertEqual(decoded.createdAt, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(decoded.configuration, configuration)
        XCTAssertEqual(decoded.endpoints.count, 4)
        XCTAssertEqual(decoded.outgoing.underruns, 2)
        XCTAssertEqual(decoded.incoming.outputCallbacks, 400)
        XCTAssertEqual(decoded.userObservations["boomMic"], "observed working")
    }
}
