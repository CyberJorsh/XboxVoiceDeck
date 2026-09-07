import XCTest
import AVFoundation
import Combine

@MainActor
final class ModelLifecycleTests: XCTestCase {
    func testMissingSelectionNeverRequestsPermissionOrStartsEngine() {
        let h = Harness(permission: .notDetermined)
        h.model.configuration = RoutingConfiguration()
        h.model.start()
        XCTAssertEqual(h.permissionRequests.count, 0)
        XCTAssertEqual(h.engine.starts.count, 0)
        XCTAssertFalse(h.model.busy)
        XCTAssertNotNil(h.model.error)
    }

    func testDeniedPermissionDoesNotPromptRepeatedly() {
        let h = Harness(permission: .denied)
        h.model.start(); h.model.start()
        XCTAssertEqual(h.permissionRequests.count, 0)
        XCTAssertEqual(h.engine.starts.count, 0)
        XCTAssertEqual(h.model.status, "PERMISSION DENIED")
        XCTAssertTrue(h.model.error?.contains("Privacy & Security") == true)
    }

    func testExplicitPermissionRequestWorksWithoutDevicesAndNeverStartsAudio() async {
        let h = Harness(permission: .notDetermined)
        h.model.configuration = RoutingConfiguration()
        h.model.start()
        XCTAssertNotNil(h.model.error)
        h.model.requestMicrophoneAccess()
        h.model.requestMicrophoneAccess(); h.model.start()
        XCTAssertEqual(h.permissionRequests.count, 1)
        XCTAssertTrue(h.model.permissionRequestPending)
        XCTAssertNil(h.model.error)
        h.permission = .authorized
        h.permissionRequests[0](true)
        await Task { @MainActor in }.value
        XCTAssertEqual(h.model.microphoneAuthorization, .authorized)
        XCTAssertFalse(h.model.permissionRequestPending)
        XCTAssertFalse(h.model.running)
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
        XCTAssertTrue(h.engine.starts.isEmpty)
    }

    func testExplicitRequestWorksEvenWhenBufferConfigurationIsInvalid() async {
        let h = Harness(permission: .notDetermined)
        h.model.configuration.requestedBuffer = 96
        h.model.requestMicrophoneAccess()
        XCTAssertEqual(h.permissionRequests.count, 1)
        h.permission = .authorized; h.permissionRequests[0](true)
        await Task { @MainActor in }.value
        h.model.start()
        XCTAssertNotNil(h.model.error)
        XCTAssertTrue(h.engine.starts.isEmpty)
    }

    func testDuplicateInputsDoNotHideTheIndependentPermissionAction() async {
        let h = Harness(permission: .notDetermined)
        h.model.configuration.headsetMicUID = "usb"
        h.model.start()
        XCTAssertTrue(h.permissionRequests.isEmpty)
        XCTAssertTrue(h.model.error?.contains("Both currently select Synthetic usb") == true)
        XCTAssertTrue(h.model.diagnostics.contains("Configured Headset microphone: Synthetic usb [2]"))
        XCTAssertTrue(h.model.diagnostics.contains("Configured Xbox audio input: Synthetic usb [2]"))
        h.model.requestMicrophoneAccess()
        h.permission = .authorized; h.permissionRequests[0](true)
        await Task { @MainActor in }.value
        XCTAssertEqual(h.model.microphoneAuthorization, .authorized)
        XCTAssertTrue(h.engine.starts.isEmpty)
    }

    func testPermissionRefreshPublishesWithoutAnInventoryChangeOrAutoStart() {
        let h = Harness(permission: .denied)
        h.model.requestMicrophoneAccess()
        XCTAssertEqual(h.model.status, "PERMISSION DENIED")
        let inventory = h.model.devices
        var changes: [AVAuthorizationStatus] = []
        let token = h.model.$microphoneAuthorization.dropFirst().sink { changes.append($0) }
        h.permission = .authorized
        h.model.refresh()
        XCTAssertEqual(changes, [.authorized])
        XCTAssertEqual(h.model.devices, inventory)
        XCTAssertTrue(h.engine.starts.isEmpty)
        XCTAssertNil(h.model.error)
        XCTAssertTrue(h.model.status.hasPrefix("STOPPED"))
        withExtendedLifetime(token) {}
    }

    func testManualDeniedAndRestrictedRequestsDoNotReprompt() {
        for permission in [AVAuthorizationStatus.denied, .restricted] {
            let h = Harness(permission: permission)
            h.model.requestMicrophoneAccess(); h.model.requestMicrophoneAccess()
            XCTAssertTrue(h.permissionRequests.isEmpty)
            XCTAssertTrue(h.engine.starts.isEmpty)
            XCTAssertNotNil(h.model.error)
            XCTAssertFalse(h.model.permissionRequestPending)
        }
    }

    func testGrantCallbackCannotOverrideUnresolvedSystemAuthorization() async {
        let h = Harness(permission: .notDetermined)
        h.model.start()
        h.permissionRequests[0](true)
        await Task { @MainActor in }.value
        XCTAssertTrue(h.engine.starts.isEmpty)
        XCTAssertFalse(h.model.busy)
        XCTAssertEqual(h.model.microphoneAuthorization, .notDetermined)
        XCTAssertEqual(h.model.status, "PERMISSION NOT GRANTED")
    }

    func testPermissionRevocationStopsLiveRoutesAndGrantDoesNotResumeThem() {
        let h = Harness(); h.start()
        h.model.xboxMuted = false; h.model.headphoneMuted = false
        h.permission = .denied
        h.model.refreshMicrophoneAuthorization()
        XCTAssertFalse(h.model.running)
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
        XCTAssertEqual(h.engine.stops.count, 1)
        h.permission = .authorized; h.model.refreshMicrophoneAuthorization()
        XCTAssertFalse(h.model.running)
        XCTAssertEqual(h.engine.starts.count, 1)
    }

    func testPermissionGrantStartsOnceAndBothOutputsStayMuted() async {
        let h = Harness(permission: .notDetermined)
        h.model.xboxMuted = false; h.model.headphoneMuted = false
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
        XCTAssertFalse(h.engine.commands.contains("mute-out:false"))
        XCTAssertFalse(h.engine.commands.contains("mute-in:false"))
        h.model.start(); h.model.start()
        h.model.xboxMuted = false; h.model.headphoneMuted = false
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
        XCTAssertFalse(h.engine.commands.contains("mute-out:false"))
        XCTAssertFalse(h.engine.commands.contains("mute-in:false"))
        XCTAssertEqual(h.permissionRequests.count, 1)
        let started = expectation(description: "Permission grant requests engine startup")
        h.engine.onStart = { started.fulfill() }
        h.permission = .authorized
        h.permissionRequests[0](true)
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(h.engine.starts.count, 1)
        h.completeStart()
        XCTAssertTrue(h.model.running)
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
        XCTAssertLessThanOrEqual(h.model.xboxDB, -60)
    }

    func testPermissionDenialFinishesPendingStart() async {
        let h = Harness(permission: .notDetermined)
        h.model.start()
        let denied = expectation(description: "Permission denial propagated")
        let token = h.model.$status.sink { if $0 == "PERMISSION DENIED" { denied.fulfill() } }
        h.permission = .denied
        h.permissionRequests[0](false)
        await fulfillment(of: [denied], timeout: 1)
        withExtendedLifetime(token) {}
        XCTAssertFalse(h.model.busy); XCTAssertFalse(h.model.running)
        XCTAssertEqual(h.engine.starts.count, 0)
    }

    func testSleepInvalidatesPendingPermissionGrantAndDenial() async {
        for granted in [false, true] {
            let h = Harness(permission: .notDetermined)
            h.model.start()
            h.model.handleSleep()
            let stoppedStatus = h.model.status
            h.permissionRequests[0](granted)
            // The permission completion queues main-actor work. Enqueuing this
            // barrier after it drains that work without time-based sleeps.
            await Task { @MainActor in }.value
            XCTAssertEqual(h.model.status, stoppedStatus)
            XCTAssertTrue(h.model.status.contains("sleeping"))
            XCTAssertEqual(h.engine.starts.count, 0)
            XCTAssertFalse(h.model.running); XCTAssertFalse(h.model.busy)
        }
    }

    func testLateStartupCompletionCannotReviveStoppedSession() {
        let h = Harness()
        h.engine.autoStop = false
        h.model.start()
        h.model.handleSleep()
        XCTAssertTrue(h.model.busy)
        h.completeStart()
        XCTAssertFalse(h.model.running)
        h.engine.stops[0]([])
        XCTAssertFalse(h.model.busy)
        XCTAssertTrue(h.model.status.contains("sleeping"))
        h.model.start(); h.completeStart()
        XCTAssertTrue(h.model.running)
        XCTAssertTrue(h.model.xboxMuted)
    }

    func testRepeatedStopAndStartWhileStoppingDoNotRace() {
        let h = Harness(); h.start()
        h.engine.autoStop = false
        h.model.stop(); h.model.stop(); h.model.start()
        XCTAssertEqual(h.engine.stops.count, 1)
        XCTAssertEqual(h.engine.starts.count, 1)
        XCTAssertTrue(h.model.busy)
        h.engine.stops[0]([])
        h.model.start(); h.completeStart()
        XCTAssertEqual(h.engine.starts.count, 2)
        XCTAssertTrue(h.model.running)
    }

    func testUnplugDuringStartupStopsImmediatelyAfterSuccessfulCompletion() {
        let h = Harness()
        h.model.start()
        let selected = try! h.model.configuration.resolve(in: h.inventory)
        h.inventory = [h.inventory[0]]
        h.model.refresh()
        h.engine.starts[0](.success(selected))
        XCTAssertFalse(h.model.running)
        XCTAssertEqual(h.engine.stops.count, 1)
        XCTAssertTrue(h.model.status.contains("DISCONNECTED"))
    }

    func testUnplugRateChangeAndDeviceIDChangeStopWithoutDefaultFallback() {
        for changed in [Harness.endpoint(id: 3, uid: "usb"), Harness.endpoint(id: 2, uid: "usb", rate: 44100)] {
            let h = Harness(); h.start()
            h.model.xboxMuted = false; h.model.headphoneMuted = false
            h.inventory = [h.inventory[0], changed]
            h.model.refresh()
            XCTAssertFalse(h.model.running)
            XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
            XCTAssertEqual(h.engine.starts.count, 1)
            XCTAssertEqual(h.model.configuration.xboxInputUID, "usb")
            h.model.refresh()
            XCTAssertEqual(h.engine.starts.count, 1, "Reconnect never automatically starts an output")
        }
    }

    func testEnumerationFailureAndStartupFailureSurfaceErrors() {
        let h = Harness()
        h.model.start()
        h.engine.starts[0](.failure(AudioFailure("Injected HAL failure")))
        XCTAssertFalse(h.model.running); XCTAssertFalse(h.model.busy)
        XCTAssertEqual(h.model.error, "Injected HAL failure")
        h.start()
        h.enumerationFailure = AudioFailure("Injected inventory failure")
        h.model.refresh()
        XCTAssertFalse(h.model.running)
        XCTAssertEqual(h.model.error, "Injected inventory failure")
    }

    func testShutdownFailureIsVisibleAndKeepsOutputsMuted() {
        let h = Harness(); h.start()
        h.engine.autoStop = false
        h.model.stop()
        h.engine.stops[0](["Injected disposal failure"])
        XCTAssertFalse(h.model.running); XCTAssertFalse(h.model.busy)
        XCTAssertEqual(h.model.error, "Injected disposal failure")
        XCTAssertEqual(h.model.status, "AUDIO ERROR — stopped")
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
    }

    func testRealtimeErrorStopsBothRoutes() {
        let h = Harness(); h.start()
        h.model.xboxMuted = false; h.model.headphoneMuted = false
        h.model.pollMeters()
        h.engine.snapshots[0](RoutingSnapshot(error: -10863))
        XCTAssertFalse(h.model.running)
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
        XCTAssertTrue(h.model.error?.contains("-10863") == true)
    }

    func testMissingSessionSnapshotStopsInsteadOfLeavingConnectedStatus() {
        let h = Harness(); h.start()
        h.model.pollMeters(); h.engine.snapshots[0](nil)
        XCTAssertFalse(h.model.running)
        XCTAssertTrue(h.model.status.contains("missing session"))
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
    }

    func testCallbackProgressAndStallUseInjectedMonotonicClock() {
        let h = Harness(); h.start()
        h.now = 1.9
        h.model.pollMeters(); h.engine.snapshots[0](Harness.snapshot(count: 1))
        XCTAssertTrue(h.model.running)
        h.now = 3.8
        h.model.pollMeters(); h.engine.snapshots[1](Harness.snapshot(count: 1))
        XCTAssertTrue(h.model.running)
        h.now = 4.0
        h.model.pollMeters(); h.engine.snapshots[2](Harness.snapshot(count: 1))
        XCTAssertFalse(h.model.running)
        XCTAssertTrue(h.model.error?.contains("stopped delivering callbacks") == true)
    }

    func testOldSnapshotCannotAffectRestartedSession() {
        let h = Harness(); h.start()
        h.model.pollMeters()
        h.model.stop(); h.start()
        h.model.pollMeters()
        XCTAssertEqual(h.engine.snapshots.count, 2, "Old pending snapshot cannot block the new session")
        h.engine.snapshots[0](RoutingSnapshot(error: -50))
        XCTAssertTrue(h.model.running)
        XCTAssertNil(h.model.error)
        h.engine.snapshots[1](Harness.snapshot(count: 1))
        XCTAssertEqual(h.model.snapshot.outgoing.inputCallbacks, 1)
    }

    func testProfileRestoreRequiresReviewAndPreservesMute() {
        let h = Harness(); h.start()
        h.model.xboxDB = -45; h.model.micGain = 1.5
        h.model.saveProfile(name: "Synthetic profile")
        let profile = h.model.profiles[0]
        h.model.xboxDB = -60; h.model.micGain = 1
        h.model.restoreProfile(profile)
        XCTAssertEqual(h.model.xboxDB, -60)
        XCTAssertNotNil(h.model.error)
        h.model.reviewedContext = h.model.calibrationContext
        h.model.xboxMuted = false; h.model.headphoneMuted = false
        h.model.restoreProfile(profile)
        XCTAssertEqual(h.model.xboxDB, -45)
        XCTAssertEqual(h.model.micGain, 1.5)
        XCTAssertTrue(h.model.xboxMuted); XCTAssertTrue(h.model.headphoneMuted)
        XCTAssertNil(h.model.reviewedContext)
        XCTAssertEqual(Array(h.engine.commands.suffix(4)), ["mute-out:true", "mute-in:true", "levels", "levels"])
        h.model.stop(); h.start()
        XCTAssertEqual(h.model.xboxDB, -60)
        XCTAssertTrue(h.model.xboxMuted)
    }

    func testToneGuardsCancellationAndLateCompletion() throws {
        let h = Harness(); h.start()
        let context = try XCTUnwrap(h.model.calibrationContext)
        h.model.confirmTone(expected: context)
        XCTAssertEqual(h.engine.tones.count, 0)
        h.model.reviewedContext = context; h.model.xboxMuted = false
        h.model.xboxDB = -30
        h.model.confirmTone(expected: context)
        XCTAssertEqual(h.engine.tones.count, 1)
        XCTAssertEqual(h.model.xboxDB, -60)
        XCTAssertTrue(h.model.toneBusy)
        h.model.cancelTone()
        h.engine.tones[0](.success(()))
        XCTAssertFalse(h.model.toneBusy)
        XCTAssertTrue(h.model.xboxMuted)
        XCTAssertTrue(h.model.calibrationMessage.contains("cancelled"))
    }

    func testToneFailureAndCompletionLatchMuteWithoutChangingIncomingMute() throws {
        for failure in [false, true] {
            let h = Harness(); h.start()
            h.model.reviewedContext = h.model.calibrationContext
            h.model.xboxMuted = false; h.model.headphoneMuted = false
            h.model.confirmTone(expected: try XCTUnwrap(h.model.calibrationContext))
            h.engine.tones[0](failure ? .failure(AudioFailure("Injected tone failure")) : .success(()))
            if !failure {
                var snapshot = Harness.snapshot(count: 1)
                snapshot.outgoing.muted = true
                h.model.pollMeters(); h.engine.snapshots[0](snapshot)
            }
            XCTAssertTrue(h.model.xboxMuted)
            XCTAssertFalse(h.model.headphoneMuted)
            XCTAssertFalse(h.model.toneBusy)
            if failure { XCTAssertEqual(h.model.error, "Injected tone failure") }
        }
    }

    func testBypassCancelsToneAndPreservesSafeGain() throws {
        let h = Harness(); h.start()
        h.model.reviewedContext = h.model.calibrationContext
        h.model.xboxMuted = false
        h.model.confirmTone(expected: try XCTUnwrap(h.model.calibrationContext))
        h.engine.tones[0](.success(()))
        h.model.micGain = 3
        let gain = h.model.xboxDB
        h.model.bypass()
        XCTAssertFalse(h.model.toneBusy)
        XCTAssertTrue(h.model.xboxMuted)
        XCTAssertEqual(h.model.xboxDB, gain)
        XCTAssertEqual(h.model.micGain, 1)
        XCTAssertTrue(h.engine.commands.contains("bypass"))
    }

    func testInjectedPreferencesPersistOnlyExplicitConfiguration() throws {
        let h = Harness()
        h.model.configuration.requestedBuffer = 64
        h.model.saveConfiguration()
        let saved = try XCTUnwrap(h.defaults.data(forKey: "routing.phase1"))
        XCTAssertEqual(try JSONDecoder().decode(RoutingConfiguration.self, from: saved).requestedBuffer, 64)
        XCTAssertNil(h.defaults.object(forKey: "xboxMuted"))
        XCTAssertNil(h.defaults.object(forKey: "headphoneMuted"))
    }
}

@MainActor
private final class Harness {
    var inventory = [endpoint(id: 1, uid: "headset"), endpoint(id: 2, uid: "usb")]
    var enumerationFailure: Error?
    var permission: AVAuthorizationStatus
    var permissionRequests: [(Bool) -> Void] = []
    var now: TimeInterval = 0
    let engine = MockRoutingEngine()
    let defaults: UserDefaults
    let suite = "XboxVoiceDeck.lifecycle.\(UUID().uuidString)"
    var model: DeckModel!
    init(permission: AVAuthorizationStatus = .authorized) {
        self.permission = permission
        defaults = UserDefaults(suiteName: suite)!
        model = DeckModel(services: DeckServices(engine: engine, enumerate: { [unowned self] in
            if let enumerationFailure = self.enumerationFailure { throw enumerationFailure }; return self.inventory
        }, authorization: { [unowned self] in self.permission }, requestPermission: { [unowned self] in
            self.permissionRequests.append($0)
        }, now: { [unowned self] in self.now }, defaults: defaults, watcher: nil, runtimeEvents: false, simulated: true))
        model.configuration = RoutingConfiguration(headsetMicUID: "headset", headsetOutputUID: "headset", xboxInputUID: "usb", xboxOutputUID: "usb")
    }
    deinit { defaults.removePersistentDomain(forName: suite) }
    func start() { model.start(); completeStart() }
    func completeStart() { engine.starts.last!(.success(try! model.configuration.resolve(in: inventory))) }
    static func snapshot(count: UInt64) -> RoutingSnapshot {
        var value = RoutingSnapshot()
        value.outgoing.inputCallbacks = count; value.outgoing.outputCallbacks = count
        value.incoming.inputCallbacks = count; value.incoming.outputCallbacks = count
        return value
    }
    static func endpoint(id: UInt32, uid: String, rate: Double = 48000) -> AudioEndpoint {
        AudioEndpoint(id: id, uid: uid, name: "Synthetic \(uid)", manufacturer: "Tests", inputChannels: 2, outputChannels: 2,
            sampleRate: rate, bufferFrames: 128, bufferRange: 32...512, supportedRates: "44100, 48000", alive: true,
            clockDomain: 0, inputLatency: 0, outputLatency: 0, inputSafety: 0, outputSafety: 0,
            inputStreamLatency: 0, outputStreamLatency: 0, inputSource: nil, outputSource: nil, inputJack: 1, outputJack: 1)
    }
}

private final class MockRoutingEngine: DeckRoutingEngine {
    var starts: [(Result<[AudioEndpoint], Error>) -> Void] = []
    var stops: [([String]) -> Void] = []
    var snapshots: [(RoutingSnapshot?) -> Void] = []
    var tones: [(Result<Void, Error>) -> Void] = []
    var commands: [String] = []
    var onStart: (() -> Void)?
    var autoStop = true
    func start(_ configuration: RoutingConfiguration, completion: @escaping (Result<[AudioEndpoint], Error>) -> Void) {
        starts.append(completion); commands.append("start"); onStart?()
    }
    func stop(completion: @escaping ([String]) -> Void) {
        stops.append(completion); commands.append("stop"); if autoStop { completion([]) }
    }
    func levels(micGain: Float, xboxDB: Float, headphoneDB: Float) { commands.append("levels") }
    func mute(_ muted: Bool, outgoing: Bool) { commands.append("mute-\(outgoing ? "out" : "in"):\(muted)") }
    func startTone(expected: CalibrationContext, completion: @escaping (Result<Void, Error>) -> Void) { tones.append(completion) }
    func cancelTone() { commands.append("cancel-tone") }
    func bypass() { commands.append("bypass") }
    func snapshot(completion: @escaping (RoutingSnapshot?) -> Void) { snapshots.append(completion) }
    func stopSynchronously() { commands.append("stop-sync") }
}
