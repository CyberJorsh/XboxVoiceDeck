import Foundation
import AVFoundation
import CoreAudio

private struct ProbeEndpoint: Encodable {
    let role: String, uid: String, name: String
    let id: UInt32, bufferFrames: UInt32
    let sampleRate: Double, inputChannels: Int, outputChannels: Int
    init(_ device: AudioEndpoint, role: String) {
        self.role = role; uid = device.uid; name = device.name; id = device.id
        sampleRate = device.sampleRate; bufferFrames = device.bufferFrames
        inputChannels = device.inputChannels; outputChannels = device.outputChannels
    }
    static func records(_ endpoints: [AudioEndpoint]) -> [ProbeEndpoint] {
        zip(endpoints, ["headsetMicrophone", "headsetOutput", "xboxInput", "xboxMicrophoneOutput"]).map { ProbeEndpoint($0, role: $1) }
    }
}

private struct ProbeCounters: Encodable {
    let inputCallbacks: UInt64, outputCallbacks: UInt64
    let underruns: UInt64, overruns: UInt64, droppedFrames: UInt64, primingDroppedFrames: UInt64, resyncs: UInt64
    let bufferedFrames: UInt32, targetFrames: UInt32
    let outputPeak: Float?, correctionPPM: Double?
    let muted: Bool, toneActive: Bool, toneFrames: UInt64
    init(_ s: DeckSnapshot) {
        inputCallbacks = s.inputCallbacks; outputCallbacks = s.outputCallbacks
        underruns = s.underruns; overruns = s.overruns; droppedFrames = s.droppedFrames; resyncs = s.resyncs
        primingDroppedFrames = s.primingDroppedFrames
        bufferedFrames = s.bufferedFrames; targetFrames = s.targetFrames
        outputPeak = s.outputPeak.isFinite ? s.outputPeak : nil
        correctionPPM = s.correctionPPM.isFinite ? s.correctionPPM : nil
        muted = s.muted; toneActive = s.toneActive; toneFrames = s.toneFrames
    }
}

private struct ProbeReport: Encodable {
    let schemaVersion = 1
    let probeVersion = "1"
    let startedAt = Date()
    var finishedAt: Date?
    let macOS = ProcessInfo.processInfo.operatingSystemVersionString
    let architecture = "arm64"
    let scope = "Four explicit AUHAL endpoints with both outputs muted; no audible or electrical acceptance."
    let physicalAcceptance = "unverified"
    let audioRecorded = false
    var status = "pending"
    var captureAttempted = false
    var requestedDurationSeconds: Double
    var observedDurationSeconds = 0.0
    var requestedConfiguration: RoutingConfiguration?
    var before: [ProbeEndpoint] = []
    var active: [ProbeEndpoint] = []
    var after: [ProbeEndpoint] = []
    var outgoing: ProbeCounters?
    var incoming: ProbeCounters?
    var realtimeError: Int32?
    var shutdownSucceeded: Bool?
    var checks: [String] = []
    var errors: [String] = []

    mutating func write(to url: URL, status: String) throws {
        self.status = status; finishedAt = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
        print("\(status.uppercased()): \(url.path)")
    }
}

private final class RoutingProbe {
    let engine = AudioRoutingEngine()
    let watcher = AudioDeviceWatcher()
    let arguments: RoutingProbeArguments
    let reportURL: URL
    var report: ProbeReport
    private var configuration: RoutingConfiguration?
    private var original: [AudioEndpoint] = []
    private var actual: [AudioEndpoint] = []
    private var timer: DispatchSourceTimer?
    private var signals: [DispatchSourceSignal] = []
    private var startupTimeout: DispatchWorkItem?
    private var shutdownTimeout: DispatchWorkItem?
    private var started: DispatchTime?
    private var lastCounts: [UInt64] = [0, 0, 0, 0]
    private var lastAdvanced: [UInt64] = []
    private var nextDeviceCheck = 1.0
    private var snapshotPending = false
    private var finishing = false

    init(arguments: RoutingProbeArguments) throws {
        self.arguments = arguments
        let path = arguments.reportPath ?? "artifacts/routing-probe-\(UUID().uuidString).json"
        reportURL = URL(fileURLWithPath: path)
        guard reportURL.standardizedFileURL != URL(fileURLWithPath: arguments.configPath).standardizedFileURL else {
            throw AudioFailure("Report must not overwrite its configuration file.")
        }
        guard !FileManager.default.fileExists(atPath: reportURL.path) else {
            throw AudioFailure("Report already exists. Choose a new --report path to preserve earlier evidence.")
        }
        try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        report = ProbeReport(requestedDurationSeconds: arguments.checkOnly ? 0 : arguments.duration)
    }

    func run() {
        do {
            let config = try arguments.loadConfiguration()
            configuration = config; report.requestedConfiguration = config
            original = try config.resolve(in: AudioDeviceManager.enumerate())
            report.before = ProbeEndpoint.records(original)
            for device in original where config.requestedBuffer != 0 && config.requestedBuffer != device.bufferFrames {
                guard device.bufferRange?.contains(config.requestedBuffer) == true else {
                    throw AudioFailure("\(device.name) does not advertise the requested \(config.requestedBuffer)-frame buffer.")
                }
                var property = AudioDeviceManager.address(kAudioDevicePropertyBufferFrameSize)
                var settable: DarwinBoolean = false
                try checkAudio(AudioObjectIsPropertySettable(device.id, &property, &settable), "Check buffer capability")
                guard settable.boolValue else { throw AudioFailure("\(device.name) buffer is read-only. Use requestedBuffer: 0.") }
            }
            report.checks.append("All four explicit UIDs resolve; channels, hardware sample rates and requested buffer capabilities are supported.")
            if arguments.checkOnly {
                report.checks.append("Configuration only: no audio units opened and no capture attempted.")
                complete(status: "configuration-valid", code: 0)
            }
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
                report.errors.append("SKIPPED: microphone permission is not already authorized for this command's host. Grant access through the app/host in System Settings > Privacy & Security > Microphone, then rerun. This tool never requests permission.")
                complete(status: "skipped", code: 3)
            }
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { [weak self] in self?.finish(error: "Interrupted by signal \(number).") }
                source.resume(); signals.append(source)
            }
            report.captureAttempted = true
            print("Starting four explicit AUHAL endpoints. Input samples stay in transient memory; both outputs remain muted.")
            let timeout = DispatchWorkItem { [weak self] in self?.finish(error: "AUHAL startup did not complete within 10 seconds.") }
            startupTimeout = timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
            engine.start(config) { [self] result in
                startupTimeout?.cancel()
                guard !finishing else { return }
                switch result {
                case .failure(let error): finish(error: error.localizedDescription)
                case .success(let endpoints):
                    actual = endpoints; report.active = ProbeEndpoint.records(endpoints)
                    report.checks.append("All four AUHAL units initialized and started on explicit devices.")
                    started = .now(); lastAdvanced = Array(repeating: DispatchTime.now().uptimeNanoseconds, count: 4)
                    watcher.watch(endpoints) { [weak self] in self?.checkDevices() }
                    let timer = DispatchSource.makeTimerSource(queue: .main)
                    timer.schedule(deadline: .now(), repeating: .milliseconds(100))
                    timer.setEventHandler { [weak self] in self?.poll() }
                    self.timer = timer; timer.resume()
                }
            }
            dispatchMain()
        } catch {
            report.errors.append(error.localizedDescription)
            complete(status: "failed", code: 1)
        }
    }

    private func checkDevices() {
        guard !finishing, let config = configuration else { return }
        do {
            let endpoints = try config.resolve(in: AudioDeviceManager.enumerate())
            guard zip(endpoints, actual).allSatisfy({ $0.runtimeSignature == $1.runtimeSignature }) else {
                throw AudioFailure("A selected device, jack, data source, sample rate or buffer changed during the probe.")
            }
        } catch { finish(error: error.localizedDescription) }
    }

    private func inspect(_ snapshot: RoutingSnapshot) -> String? {
        report.outgoing = ProbeCounters(snapshot.outgoing); report.incoming = ProbeCounters(snapshot.incoming)
        report.realtimeError = snapshot.error
        if snapshot.error != 0 { return "Realtime audio error: \(snapshot.error)." }
        for (name, route) in [("outgoing", snapshot.outgoing), ("incoming", snapshot.incoming)] {
            if !route.muted || route.toneActive || route.toneFrames != 0 || route.outputPeak != 0 || route.outputRMS != 0 {
                return "Safety check failed: \(name) route must remain muted with zero output and no tone."
            }
            if RoutingProbeValidation.hasUnexpectedBufferEvents(route) {
                return "Stability check failed: \(name) route has underruns, overruns, non-priming dropped frames or resyncs. Try a larger supported buffer."
            }
        }
        return nil
    }

    private func poll() {
        guard !finishing, let started else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        report.observedDurationSeconds = Double(now - started.uptimeNanoseconds) / 1_000_000_000
        if report.observedDurationSeconds >= nextDeviceCheck {
            nextDeviceCheck = report.observedDurationSeconds + 1
            checkDevices()
            guard !finishing else { return }
        }
        if report.observedDurationSeconds >= arguments.duration { finish(); return }
        guard !snapshotPending else { return }
        snapshotPending = true
        engine.snapshot { [self] snapshot in
            snapshotPending = false
            guard !finishing else { return }
            guard let snapshot else { finish(error: "Running session unexpectedly disappeared."); return }
            if let error = inspect(snapshot) { finish(error: error); return }
            let counts = [snapshot.outgoing.inputCallbacks, snapshot.outgoing.outputCallbacks,
                          snapshot.incoming.inputCallbacks, snapshot.incoming.outputCallbacks]
            let now = DispatchTime.now().uptimeNanoseconds
            for index in counts.indices {
                if counts[index] > lastCounts[index] { lastAdvanced[index] = now }
                if now - lastAdvanced[index] > 1_000_000_000 {
                    finish(error: "Callback stream \(index + 1) stalled for more than one second."); return
                }
            }
            lastCounts = counts
        }
    }

    private func finish(error: String? = nil) {
        guard !finishing else { return }
        finishing = true; startupTimeout?.cancel(); timer?.cancel(); watcher.clear()
        if let error { report.errors.append(error) }
        // Protect the CLI from an unresponsive driver/control queue. Process exit
        // is explicitly a failed cleanup, never a successful audio shutdown.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.report.shutdownSucceeded = false
            self.report.errors.append("Shutdown did not complete within 10 seconds; terminating this probe process.")
            self.complete(status: "failed", code: 1)
        }
        shutdownTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        engine.snapshot { [self] snapshot in
            if let snapshot {
                if let error = inspect(snapshot), !report.errors.contains(error) { report.errors.append(error) }
                let counts = [snapshot.outgoing.inputCallbacks, snapshot.outgoing.outputCallbacks,
                              snapshot.incoming.inputCallbacks, snapshot.incoming.outputCallbacks]
                if counts.contains(where: { $0 < 2 }) { report.errors.append("One or more input/output streams did not produce repeated callbacks.") }
            } else if report.errors.isEmpty { report.errors.append("No active session was available for final checks.") }
            engine.stop { [self] errors in
                shutdownTimeout?.cancel()
                report.shutdownSucceeded = errors.isEmpty
                report.errors.append(contentsOf: errors)
                do {
                    guard let configuration else { throw AudioFailure("Configuration unavailable after shutdown.") }
                    let restored = try configuration.resolve(in: AudioDeviceManager.enumerate())
                    report.after = ProbeEndpoint.records(restored)
                    if zip(restored, original).contains(where: { $0.runtimeSignature != $1.runtimeSignature }) {
                        report.errors.append("Devices, formats, buffers or jack/source state differ from the pre-run values after shutdown; another application or hardware change may be involved.")
                    }
                } catch { report.errors.append("Post-shutdown inventory: \(error.localizedDescription)") }
                if report.errors.isEmpty {
                    report.checks.append("Both capture and output callback pairs advanced with digital-zero output, mute retained, no tone, and no buffer errors.")
                    report.checks.append("AUHAL shutdown completed and original hardware buffer sizes were observed afterward.")
                }
                complete(status: report.errors.isEmpty ? "muted-run-passed" : "failed", code: report.errors.isEmpty ? 0 : 1)
            }
        }
    }

    private func complete(status: String, code: Int32) -> Never {
        for error in report.errors { fputs("\(error)\n", stderr) }
        do { try report.write(to: reportURL, status: status) }
        catch { fputs("Could not save report: \(error.localizedDescription)\n", stderr); exit(1) }
        exit(code)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] { print(RoutingProbeArguments.usage); exit(0) }
if arguments == ["--self-test"] {
    do { try runRoutingProbeArgumentTests(); exit(0) }
    catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
}
do {
    let options: RoutingProbeArguments
    do { options = try RoutingProbeArguments(arguments) }
    catch { fputs("\(error.localizedDescription)\n\n\(RoutingProbeArguments.usage)\n", stderr); exit(2) }
    try RoutingProbe(arguments: options).run()
} catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
