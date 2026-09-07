import SwiftUI
import AVFoundation
import AppKit
import OSLog

@MainActor
final class DeckModel: ObservableObject {
    @Published var devices: [AudioEndpoint] = []
    @Published var configuration = RoutingConfiguration() {
        didSet { endpointTests.validate(devices: devices, configuration: configuration, captureAllowed: microphoneAuthorization == .authorized) }
    }
    let endpointTests: EndpointTestModel
    @Published var status = "STOPPED — select four endpoints"
    @Published var error: String?
    @Published var running = false
    @Published var busy = false
    @Published var snapshot = RoutingSnapshot()
    @Published var xboxDB: Double = -60 { didSet { updateLevels() } }
    @Published var headphoneDB: Double = -20 { didSet { updateLevels() } }
    @Published var micGain: Double = 1 { didSet { updateLevels() } }
    @Published var xboxMuted = true {
        didSet {
            if (!running || busy) && !xboxMuted { xboxMuted = true; return }
            engine.mute(xboxMuted, outgoing: true)
        }
    }
    @Published var headphoneMuted = true {
        didSet {
            if (!running || busy) && !headphoneMuted { headphoneMuted = true; return }
            engine.mute(headphoneMuted, outgoing: false)
        }
    }
    @Published private(set) var profiles: [CalibrationProfile] = []
    @Published var calibrationMessage = "Physical calibration pending. Saved levels are not electrical certification."
    @Published var reviewedContext: CalibrationContext?
    @Published private(set) var toneBusy = false
    @Published private(set) var offlineBusy = false
    @Published private(set) var offlineResult: OfflineSafetyResult?
    private let calibrationStore: CalibrationStore
    private let services: DeckServices
    @Published private(set) var microphoneAuthorization: AVAuthorizationStatus
    @Published private(set) var permissionRequestPending = false
    var isSimulated: Bool { services.simulated }
    private var toneGeneration = 0
    private var toneRequestPending = false
    private var inactivityObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private let engine: DeckRoutingEngine
    private var meterTimer: Timer?
    private var inventoryTimer: Timer?
    private var activeEndpoints: [AudioEndpoint] = []
    private var watchedIDs: [AudioDeviceID] = []
    private var lastCounts: [UInt64] = []
    private var lastProgress: [TimeInterval] = []
    private var lastXruns: [UInt64] = []
    private var snapshotPending = false
    private var sessionGeneration: UInt64 = 0
    private var terminationObserver: NSObjectProtocol?
    private var startGate = RoutingStartGate()
    private var stopping = false

    init(services: DeckServices = .live()) {
        self.services = services
        self.engine = services.engine
        self.endpointTests = EndpointTestModel(engine: services.endpointTester, now: services.now)
        self.microphoneAuthorization = services.authorization()
        self.calibrationStore = CalibrationStore(defaults: services.defaults)
        Logger.audio.info("Application launch")
        if let saved = services.defaults.data(forKey: "routing.phase1"),
           let loaded = try? JSONDecoder().decode(RoutingConfiguration.self, from: saved) { configuration = loaded }
        do { profiles = try calibrationStore.load() }
        catch { self.error = "Cannot load calibration profiles: \(error.localizedDescription)" }
        refresh()
        guard services.runtimeEvents else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
        // Low-frequency verification backs up property notifications and resolves
        // UIDs after reconnect; it is not audio-thread synchronization.
        inventoryTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            // Termination must synchronously silence/dispose the live session.
            MainActor.assumeIsolated { self?.endpointTests.shutdown(); self?.engine.stopSynchronously() }
        }
        inactivityObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancelTone(); self?.endpointTests.stop("Test stopped: app inactive.") }
        }
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshMicrophoneAuthorization() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleSleep()
            }
        }
    }

    func handleSleep() {
        endpointTests.stop("Test stopped: Mac sleeping.")
        cancelTone()
        if running || busy { stop(reason: "STOPPED — Mac sleeping; restart explicitly") }
    }

    func refresh() {
        refreshMicrophoneAuthorization()
        do {
            let updated = try services.enumerate()
            if devices != updated {
                Logger.audio.info("Device inventory, rate, buffer or jack state changed")
                devices = updated
            }
            endpointTests.validate(devices: updated, configuration: configuration, captureAllowed: microphoneAuthorization == .authorized)
            let ids = updated.map(\.id)
            if watchedIDs != ids || watchedIDs.isEmpty {
                watchedIDs = ids
                services.watcher?.watch(updated) { [weak self] in self?.refresh() }
            }
            if running && !busy {
                let current = updated.filter { device in activeEndpoints.contains { $0.uid == device.uid } }
                if current.count != Set(activeEndpoints.map(\.uid)).count || activeEndpoints.contains(where: { old in
                    !current.contains { $0.uid == old.uid && $0.runtimeSignature == old.runtimeSignature }
                }) {
                    stop(reason: "DISCONNECTED / CONFIGURATION CHANGED — both routes stopped. Check devices, rate and headset jack; restart explicitly.")
                }
            }
        } catch {
            self.error = error.localizedDescription
            endpointTests.stop("AUDIO ERROR: device enumeration failed.")
            if running { stop(reason: "AUDIO ERROR — device enumeration failed") }
        }
    }

    func start() {
        guard !busy, !running, !permissionRequestPending, !endpointTests.busy else { return }
        refreshMicrophoneAuthorization()
        error = nil
        do { _ = try configuration.resolve(in: devices) }
        catch { self.error = error.localizedDescription; return }
        busy = true
        let request = startGate.begin()
        switch microphoneAuthorization {
        case .authorized: beginRouting(request: request)
        case .notDetermined:
            status = "Waiting for microphone permission"
            requestAuthorization { [weak self] allowed in
                guard let self, self.startGate.accepts(request) else { return }
                if allowed { self.beginRouting(request: request) } else { self.permissionDenied(request: request) }
            }
        default: permissionDenied(request: request)
        }
    }
    private func permissionDenied(request: UUID) {
        guard startGate.finish(request) else { return }
        busy = false
        showPermissionFailure()
    }

    // Permission is independent of device setup and must never start audio here.
    func requestMicrophoneAccess() {
        guard !permissionRequestPending, !busy, !running else { return }
        refreshMicrophoneAuthorization()
        switch microphoneAuthorization {
        case .authorized: return
        case .notDetermined:
            error = nil
            requestAuthorization { [weak self] allowed in
                guard let self else { return }
                if allowed {
                    self.status = "STOPPED — microphone access granted; select your devices, then Start muted"
                } else { self.showPermissionFailure() }
            }
        default: showPermissionFailure()
        }
    }

    private func requestAuthorization(completion: @escaping (Bool) -> Void) {
        permissionRequestPending = true
        services.requestPermission { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                self.permissionRequestPending = false
                self.refreshMicrophoneAuthorization()
                completion(allowed && self.microphoneAuthorization == .authorized)
            }
        }
    }

    func refreshMicrophoneAuthorization() {
        let current = services.authorization()
        guard current != microphoneAuthorization else { return }
        microphoneAuthorization = current
        endpointTests.validate(devices: devices, configuration: configuration, captureAllowed: current == .authorized)
        Logger.audio.info("Microphone authorization changed: \(current.rawValue)")
        if current != .authorized && running {
            error = "Microphone permission is no longer granted. Both routes have been stopped."
            stop(reason: "PERMISSION DENIED — restart explicitly after granting access")
        } else if current == .authorized && !running && !busy && status.hasPrefix("PERMISSION ") {
            error = nil
            status = "STOPPED — microphone access granted; select your devices, then Start muted"
        }
    }

    private var permissionDescription: String {
        switch microphoneAuthorization {
        case .notDetermined: return "not requested"
        case .authorized: return "granted"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    private func showPermissionFailure() {
        switch microphoneAuthorization {
        case .restricted:
            status = "PERMISSION RESTRICTED"
            error = "macOS restricts microphone access. Check Screen Time or administrator restrictions. The app cannot override this policy."
        case .notDetermined:
            status = "PERMISSION NOT GRANTED"
            error = "macOS did not finish granting microphone access. Open the built XboxVoiceDeck.app (not its internal executable), check for a permission dialog, then Refresh permission. An app may not appear in Microphone settings until macOS processes its access request."
        default:
            status = "PERMISSION DENIED"
            error = "Microphone access is required for both inputs. Open System Settings → Privacy & Security → Microphone and enable Xbox Voice Deck, then return and Refresh permission. Restart the app if macOS requests it."
        }
    }
    private func beginRouting(request: UUID) {
        guard startGate.accepts(request) else { return }
        refreshMicrophoneAuthorization()
        guard microphoneAuthorization == .authorized else { permissionDenied(request: request); return }
        reviewedContext = nil
        xboxMuted = true; headphoneMuted = true; xboxDB = min(xboxDB, -60)
        status = "Starting explicit AUHAL routes…"
        let requested = configuration
        engine.start(requested) { [weak self] result in
            guard let self, self.startGate.finish(request) else { return }
            self.busy = false
            switch result {
            case .success(let endpoints):
                self.activeEndpoints = endpoints
                self.lastCounts = [0, 0, 0, 0]
                self.sessionGeneration &+= 1
                self.snapshotPending = false
                self.lastProgress = Array(repeating: self.services.now(), count: 4)
                self.lastXruns = []
                self.running = true
                self.status = "CONNECTED — both outputs muted; check meters before unmuting"
                self.updateLevels()
                self.saveConfiguration()
                self.refresh()
            case .failure(let error): self.status = "AUDIO ERROR"; self.error = error.localizedDescription
            }
        }
    }
    func stop(reason: String = "STOPPED") {
        endpointTests.stop()
        guard !stopping else { return }
        startGate.cancel()
        sessionGeneration &+= 1
        snapshotPending = false
        stopping = true
        cancelTone(); reviewedContext = nil
        busy = true
        xboxMuted = true; headphoneMuted = true
        engine.stop { [weak self] errors in
            self?.stopping = false
            self?.running = false; self?.busy = false; self?.status = reason
            self?.snapshot = RoutingSnapshot(); self?.activeEndpoints = []
            if !errors.isEmpty { self?.error = errors.joined(separator: "\n"); self?.status = "AUDIO ERROR — stopped" }
        }
    }
    func bypass() {
        endpointTests.stop("Test stopped by Bypass All.")
        cancelTone()
        micGain = 1
        engine.bypass()
        status = running ? "BYPASS — normal mic, output gains and mutes preserved" : "STOPPED — normal mic selected"
    }
    func saveConfiguration() {
        do {
            let data = try JSONEncoder().encode(configuration)
            services.defaults.set(data, forKey: "routing.phase1")
            Logger.audio.info("Explicit device selection saved")
        } catch { self.error = "Cannot save configuration: \(error.localizedDescription)" }
    }
    private func updateLevels() {
        engine.levels(micGain: Float(micGain), xboxDB: Float(xboxDB), headphoneDB: Float(headphoneDB))
    }
    func pollMeters() {
        endpointTests.poll()
        guard running, !busy, !snapshotPending else { return }
        snapshotPending = true
        let generation = sessionGeneration
        engine.snapshot { [weak self] value in
            guard let self, self.sessionGeneration == generation else { return }
            self.snapshotPending = false
            guard self.running, !self.busy else { return }
            guard let value else {
                self.error = "The active audio session became unavailable. Both routes have been stopped."
                self.stop(reason: "AUDIO ERROR — missing session")
                return
            }
            self.snapshot = value
            if self.toneBusy && !self.toneRequestPending && !value.outgoing.toneActive && value.outgoing.muted {
                self.toneBusy = false
                self.xboxMuted = true
                self.calibrationMessage = "Tone stopped. Xbox output is muted; physical calibration remains pending."
            }
            if value.error != 0 {
                self.error = "Realtime callback failed with Core Audio status \(value.error). Both routes were silenced."
                self.stop(reason: "AUDIO ERROR")
                return
            }
            let counts = [value.outgoing.inputCallbacks, value.outgoing.outputCallbacks, value.incoming.inputCallbacks, value.incoming.outputCallbacks]
            for index in counts.indices {
                if counts[index] != self.lastCounts[index] { self.lastProgress[index] = self.services.now() }
            }
            self.lastCounts = counts
            if self.lastProgress.contains(where: { self.services.now() - $0 > 2 }) {
                self.error = "An audio endpoint stopped delivering callbacks. Both routes have been stopped."
                self.stop(reason: "AUDIO ERROR — stalled device")
            }
            let xruns = [value.outgoing.underruns, value.outgoing.overruns, value.incoming.underruns, value.incoming.overruns]
            if xruns != self.lastXruns {
                Logger.audio.info("App buffer underrun/overrun counters: \(xruns.description, privacy: .public)")
                self.lastXruns = xruns
            }
        }
    }
    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
    }
    func prepareEndpointTest(_ role: EndpointRole) -> EndpointTestRequest? {
        guard !running, !busy, !permissionRequestPending, !endpointTests.busy else { return nil }
        refreshMicrophoneAuthorization()
        if role.input && microphoneAuthorization != .authorized {
            requestMicrophoneAccess()
            if microphoneAuthorization == .notDetermined { status = "Grant microphone access, then click Test input again." }
            return nil
        }
        do { return try EndpointTestRequest(role: role, configuration: configuration, devices: devices) }
        catch { self.error = error.localizedDescription; return nil }
    }
    func startEndpointTest(_ request: EndpointTestRequest) {
        guard !running, !busy, !permissionRequestPending, !endpointTests.busy else { return }
        refreshMicrophoneAuthorization()
        do {
            let current = try EndpointTestRequest(role: request.role, configuration: configuration, devices: devices)
            guard current == request, !request.role.input || microphoneAuthorization == .authorized else {
                throw AudioFailure("Endpoint or permission changed. Request the test again.")
            }
            error = nil
            endpointTests.start(request)
        } catch { self.error = error.localizedDescription }
    }
    func latency(outgoing: Bool) -> String {
        guard activeEndpoints.count == 4 else { return "Start routing to estimate latency" }
        let input = activeEndpoints[outgoing ? 0 : 2]
        let output = activeEndpoints[outgoing ? 3 : 1]
        let frames = outgoing ? snapshot.outgoing.targetFrames : snapshot.incoming.targetFrames
        guard frames > 0 else { return "Priming…" }
        let software = 1000 * ((Double(input.bufferFrames + frames + 32) / input.sampleRate) + Double(output.bufferFrames) / output.sampleRate)
        let device = 1000 * (Double(input.inputLatency + input.inputSafety + input.inputStreamLatency) / input.sampleRate + Double(output.outputLatency + output.outputSafety + output.outputStreamLatency) / output.sampleRate)
        return String(format: "Estimated software budget %.1f ms + reported device latency %.1f ms (unmeasured)", software, device)
    }
    var diagnostics: String {
        var lines = [isSimulated ? "SIMULATED TEST SESSION — no hardware audio or physical validation" : "Xbox Voice Deck — Phase 2 software; physical calibration pending", "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
                     "Architecture: \(machineValue("hw.machine")) · Model: \(machineValue("hw.model"))", status,
                     "Version: \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"))",
                     "Format: Float32 at source device rate; one adaptive SRC per direction", "Permission: \(microphoneAuthorization.rawValue) (\(permissionDescription)); request pending: \(permissionRequestPending)",
                     "Xbox: \(xboxDB) dB, mute \(xboxMuted); Headphones: \(headphoneDB) dB, mute \(headphoneMuted)",
                     "Active endpoint IDs: \(activeEndpoints.isEmpty ? "none" : activeEndpoints.map { String($0.id) }.joined(separator: ", "))"]
        let roles = ["Headset microphone", "Headset output", "Xbox audio input", "Xbox mic output"]
        for (index, uid) in configuration.selectedUIDs.enumerated() {
            let selection = devices.first { $0.uid == uid }.map { "\($0.name) [\($0.id)]" }
                ?? (uid.isEmpty ? "not selected" : "missing saved device")
            lines.append("Configured \(roles[index]): \(selection)")
        }
        lines.append("Configured channels: mic \(configuration.micChannel + 1), Xbox first \(configuration.xboxFirstChannel + 1), \(configuration.xboxStereo ? "stereo" : "mono"); requested buffer \(configuration.requestedBuffer)")
        lines.append("Endpoint test: \(endpointTests.request?.role.title ?? "none"); \(endpointTests.message); callbacks \(endpointTests.reading.callbacks), peak \(endpointTests.reading.peak), error \(endpointTests.reading.error)")
        for device in devices {
            lines += ["\n\(device.name) — \(device.manufacturer)", device.summary,
                      "Rates: \(device.supportedRates); clock domain \(device.clockDomain)",
                      "Buffer range: \(String(describing: device.bufferRange)); alive: \(device.alive)",
                      "Device latency in/out: \(device.inputLatency)/\(device.outputLatency) frames; safety: \(device.inputSafety)/\(device.outputSafety); stream: \(device.inputStreamLatency)/\(device.outputStreamLatency)",
                      "Jack in/out: \(String(describing: device.inputJack))/\(String(describing: device.outputJack)); source in/out: \(String(describing: device.inputSource))/\(String(describing: device.outputSource))"]
        }
        for (name, s) in [("Outgoing", snapshot.outgoing), ("Incoming", snapshot.incoming)] {
            lines += ["\n\(name): queue \(s.bufferedFrames)/\(s.targetFrames); ASRC \(String(format: "%.1f", s.correctionPPM)) ppm",
                      "Underruns \(s.underruns), overruns \(s.overruns), dropped \(s.droppedFrames), resyncs \(s.resyncs)",
                      "Callbacks input/output: \(s.inputCallbacks)/\(s.outputCallbacks); digital ceiling hits: \(s.limitedSamples)",
                      "Limiter: \(String(format: "%.1f", s.limiterReductionDB)) dB reduction, \(s.limiterFrames) frames; zero look-ahead frames",
                      "Tone active: \(s.toneActive), generated frames: \(s.toneFrames), remaining: \(s.toneFramesRemaining); kernel mute: \(s.muted)"]
        }
        lines += [latency(outgoing: true), latency(outgoing: false), "Callback error: \(snapshot.error)"]
        if let error { lines.append(error) }
        return lines.joined(separator: "\n")
    }
    func copyDiagnostics() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnostics, forType: .string) }
    var calibrationContext: CalibrationContext? {
        try? CalibrationContext(configuration: configuration, devices: running ? activeEndpoints : devices)
    }
    var calibrationReviewed: Bool { calibrationContext != nil && reviewedContext == calibrationContext }
    func saveProfile(name: String) {
        guard running, !busy, !toneBusy, let context = calibrationContext else {
            error = "Start the four selected endpoints before saving their actual format and buffer configuration."; return
        }
        do {
            profiles = try calibrationStore.save(name: name, context: context, xboxDB: xboxDB, micGain: micGain)
            calibrationMessage = "Profile saved locally. Physical calibration pending. It will never automatically unmute or restore gain."
        } catch { self.error = error.localizedDescription }
    }
    func restoreProfile(_ profile: CalibrationProfile) {
        guard running, !busy, !toneBusy, let context = calibrationContext else { error = "Start routing muted before reviewing and restoring a profile."; return }
        do {
            let settings = try profile.reviewedSettings(for: context, acknowledged: calibrationReviewed)
            xboxMuted = true; headphoneMuted = true
            micGain = settings.micGain; xboxDB = settings.xboxDB
            reviewedContext = nil
            calibrationMessage = "Restored \(profile.name). Both outputs remain muted. Recheck wiring and levels before manually unmuting."
        } catch { self.error = error.localizedDescription }
    }
    func deleteProfile(_ profile: CalibrationProfile) {
        do { profiles = try calibrationStore.delete(id: profile.id) }
        catch { self.error = error.localizedDescription }
    }
    func confirmTone(expected: CalibrationContext) {
        guard running, !busy, !toneBusy, !xboxMuted, calibrationReviewed, calibrationContext == expected else {
            error = "Review this setup, start routing, and explicitly unmute Xbox output before confirming a tone."; return
        }
        toneGeneration += 1
        let generation = toneGeneration
        toneBusy = true; toneRequestPending = true
        xboxDB = min(xboxDB, -60)
        engine.startTone(expected: expected) { [weak self] result in
            guard let self, self.toneGeneration == generation else { return }
            self.toneRequestPending = false
            switch result {
            case .success: self.calibrationMessage = "Low-level tone active for at most two seconds. Xbox output will mute afterward."
            case .failure(let error):
                self.toneBusy = false; self.xboxMuted = true; self.error = error.localizedDescription
            }
        }
    }
    func cancelTone() {
        toneGeneration += 1
        engine.cancelTone()
        if toneBusy {
            xboxMuted = true
            calibrationMessage = "Tone cancelled. Xbox output muted."
        }
        toneBusy = false; toneRequestPending = false
    }
    func runOfflineCheck() {
        guard !offlineBusy, !running, !busy else { return }
        offlineBusy = true; offlineResult = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = OfflineSafetyCheck.run()
            DispatchQueue.main.async { self?.offlineResult = result; self?.offlineBusy = false }
        }
    }
    private func machineValue(_ key: String) -> String {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0 else { return "Unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else { return "Unknown" }
        return String(cString: bytes)
    }
}
