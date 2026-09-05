import Foundation
import AudioToolbox

// Standalone component probe. It never captures a microphone or routes audible
// audio. An explicit ID is required even for the silent output test.
do {
    let devices = try AudioDeviceManager.enumerate()
    for device in devices {
        print("\(device.name) | \(device.summary) | \(device.manufacturer) | rates: \(device.supportedRates) | clock: \(device.clockDomain)")
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--silent-output",
       let id = UInt32(CommandLine.arguments[2]), let device = devices.first(where: { $0.id == id && $0.outputChannels > 0 }) {
        let safety = DeckSafetyCreate()!
        let route = DeckRouteCreate(device.sampleRate, device.sampleRate, device.bufferFrames, device.bufferFrames, 1, true)!
        let unit = try HALUnit(device: device, capture: false)
        let context = DeckOutputCreate(route, safety, unit.channels, unit.maxFrames)!
        try unit.attach(context: UnsafeMutableRawPointer(context))
        try unit.start()
        print("Explicit output ID \(id), AUHAL initialized and started. All samples zero; no input unit.")
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let deadline = Date().addingTimeInterval(5)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler {
            let snapshot = DeckRouteSnapshot(route)
            let error = DeckSafetyError(safety)
            if snapshot.outputCallbacks >= 200 || error != 0 || Date() >= deadline {
                timer.cancel()
                let stopped = unit.close()
                print("Silent output callbacks: \(snapshot.outputCallbacks), realtime error: \(error), stop status: \(stopped), output peak: \(snapshot.outputPeak)")
                if unit.disposed {
                    DeckOutputDestroy(context)
                    DeckRouteDestroy(route)
                    DeckSafetyDestroy(safety)
                }
                exit(snapshot.outputCallbacks >= 200 && error == 0 && stopped == 0 && snapshot.outputPeak == 0 ? 0 : 1)
            }
        }
        timer.resume()
        dispatchMain()
    } else if CommandLine.arguments.count > 1 {
        throw AudioFailure("Usage: device-probe [--silent-output CORE_AUDIO_ID]")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
