import Foundation
import AudioToolbox

// This probe has no capture unit and never asks for microphone permission.
private let usage = """
Usage: device-probe [--json | --silent-output CORE_AUDIO_ID | --help]
No arguments lists devices, including stable UIDs. --json prints the same inventory
as JSON. --silent-output requires one explicit live output at 44.1 or 48 kHz;
it emits digital zero for up to five seconds. It does not test microphone capture.
"""

private struct DeviceRecord: Encodable {
    let id: UInt32, uid: String, name: String, manufacturer: String
    let inputChannels: Int, outputChannels: Int, sampleRate: Double, bufferFrames: UInt32
    let supported: Bool, supportedRates: String
    init(_ d: AudioEndpoint) {
        id = d.id; uid = d.uid; name = d.name; manufacturer = d.manufacturer
        inputChannels = d.inputChannels; outputChannels = d.outputChannels
        sampleRate = d.sampleRate; bufferFrames = d.bufferFrames
        supported = d.supported; supportedRates = d.supportedRates
    }
}

private final class SilentOutputProbe {
    private var safety: OpaquePointer?
    private var route: OpaquePointer?
    private var context: OpaquePointer?
    private var unit: HALUnit?
    private var closed = false

    init(device: AudioEndpoint) throws {
        guard device.alive, device.supported, (1...32).contains(device.outputChannels),
              (1...4096).contains(device.bufferFrames) else {
            throw AudioFailure("UNSUPPORTED FORMAT: silent output requires a live 44.1/48 kHz device, 1–32 output channels and a 1–4096 frame buffer.")
        }
        do {
            guard let safety = DeckSafetyCreate() else { throw AudioFailure("Cannot create lock-free safety state.") }
            self.safety = safety
            guard let route = DeckRouteCreate(device.sampleRate, device.sampleRate, device.bufferFrames, device.bufferFrames, 1, true) else {
                throw AudioFailure("Cannot allocate the silent route.")
            }
            self.route = route
            let unit = try HALUnit(device: device, capture: false)
            self.unit = unit
            guard let context = DeckOutputCreate(route, safety, unit.channels, unit.maxFrames) else {
                throw AudioFailure("Cannot allocate the silent output callback.")
            }
            self.context = context
            try unit.attach(context: UnsafeMutableRawPointer(context))
            try unit.start()
        } catch {
            let shutdown = close()
            throw AudioFailure(error.localizedDescription + (shutdown == noErr ? "" : "\nShutdown error: \(shutdown)"))
        }
    }

    func sample() -> (DeckSnapshot, Int32) { (DeckRouteSnapshot(route!), DeckSafetyError(safety!)) }

    @discardableResult func close() -> OSStatus {
        guard !closed else { return noErr }
        closed = true
        if let route { DeckRouteSetMuted(route, true) }
        if let safety { DeckSafetyTrip(safety, -1) }
        let status = unit?.close() ?? noErr
        // A failed HAL disposal must never release memory a callback might use.
        // The process is about to exit; retain those silenced C allocations.
        guard unit == nil || unit?.disposed == true else { return status }
        if let context { DeckOutputDestroy(context) }
        if let route { DeckRouteDestroy(route) }
        if let safety { DeckSafetyDestroy(safety) }
        self.context = nil; self.route = nil; self.safety = nil
        return status
    }
    deinit { close() }
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] { print(usage); exit(0) }
    guard arguments.isEmpty || arguments == ["--json"] ||
            (arguments.count == 2 && arguments[0] == "--silent-output" && UInt32(arguments[1]) != nil) else {
        throw AudioFailure(usage)
    }
    let devices = try AudioDeviceManager.enumerate()
    if arguments == ["--json"] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(devices.map(DeviceRecord.init)), as: UTF8.self))
    } else if arguments.isEmpty {
        for device in devices {
            print("\(device.name) | \(device.summary) | UID: \(device.uid) | \(device.manufacturer) | rates: \(device.supportedRates) | clock: \(device.clockDomain)")
        }
    } else {
        let id = UInt32(arguments[1])!
        guard let device = devices.first(where: { $0.id == id }) else { throw AudioFailure("MISSING: Core Audio device ID \(id). Run device-probe again; IDs can change.") }
        let probe = try SilentOutputProbe(device: device)
        print("Explicit output ID \(id), AUHAL started with digital silence; no input unit.")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let deadline = DispatchTime.now() + 5
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            let (snapshot, error) = probe.sample()
            if snapshot.outputCallbacks >= 200 || error != 0 || DispatchTime.now() >= deadline {
                timer.cancel()
                let stopped = probe.close()
                print("Silent output callbacks: \(snapshot.outputCallbacks), realtime error: \(error), stop status: \(stopped), output peak: \(snapshot.outputPeak)")
                exit(snapshot.outputCallbacks >= 200 && error == 0 && stopped == 0 && snapshot.outputPeak == 0 && snapshot.muted ? 0 : 1)
            }
        }
        timer.resume()
        dispatchMain()
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
