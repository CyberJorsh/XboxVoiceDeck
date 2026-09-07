import Foundation

// Wait only on the audio control queue, never the UI or a realtime callback.
// Read after notifications because an accepted HAL write need not apply immediately.
enum BufferChange {
    struct Unsettled: LocalizedError {
        let errorDescription: String?
    }
    static func waitForValue(_ requested: UInt32, timeout: TimeInterval = 2,
                             read: () throws -> UInt32, write: () throws -> Void,
                             subscribe: (@escaping () -> Void) throws -> (() -> Void),
                             requireNotification: Bool = false) throws {
        let changed = DispatchSemaphore(value: 0)
        let unsubscribe = try subscribe { changed.signal() }
        defer { unsubscribe() }
        let deadline = DispatchTime.now() + timeout
        try write()
        do {
            if !requireNotification, try read() == requested { return }
            while DispatchTime.now() < deadline, changed.wait(timeout: deadline) == .success {
                if try read() == requested { return }
            }
            throw AudioFailure("Timed out waiting for the hardware buffer to become \(requested) frames. The driver may still apply the request. Routing stays stopped; check Audio MIDI Setup and try Keep hardware. Any rollback failure is reported below.")
        } catch { throw Unsettled(errorDescription: error.localizedDescription) }

    }
}

struct DeviceInventory {
    var devices: [AudioEndpoint]
    var issues: [String] = []
    var defaultOutput: UInt32?
    var alertOutput: UInt32?
}

final class DeviceDiscovery {
    private let queue = DispatchQueue(label: "XboxVoiceDeck.device-discovery", qos: .userInitiated)
    func discover(completion: @escaping (Result<DeviceInventory, Error>) -> Void) {
        queue.async {
            let result = Result { try AudioDeviceManager.inventory() }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
