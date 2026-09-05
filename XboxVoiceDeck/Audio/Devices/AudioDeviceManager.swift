import CoreAudio
import Foundation

struct AudioFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioFailure("\(operation): Core Audio error \(status)") }
}

struct AudioEndpoint: Identifiable, Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let manufacturer: String
    let inputChannels: Int
    let outputChannels: Int
    let sampleRate: Double
    let bufferFrames: UInt32
    let bufferRange: ClosedRange<UInt32>?
    let supportedRates: String
    let alive: Bool
    let clockDomain: UInt32
    let inputLatency: UInt32
    let outputLatency: UInt32
    let inputSafety: UInt32
    let outputSafety: UInt32
    let inputStreamLatency: UInt32
    let outputStreamLatency: UInt32
    let inputSource: UInt32?
    let outputSource: UInt32?
    let inputJack: UInt32?
    let outputJack: UInt32?

    var supported: Bool { [44100.0, 48000.0].contains(sampleRate) && alive }
    var summary: String { "ID \(id) · \(inputChannels) in / \(outputChannels) out · \(Int(sampleRate)) Hz · \(bufferFrames) frames" }
    var runtimeSignature: String {
        "\(id):\(uid):\(inputChannels):\(outputChannels):\(sampleRate):\(bufferFrames):\(alive):\(String(describing: inputSource)):\(String(describing: outputSource)):\(String(describing: inputJack)):\(String(describing: outputJack))"
    }
}

enum AudioDeviceManager {
    static let global = kAudioObjectPropertyScopeGlobal
    static let input = kAudioObjectPropertyScopeInput
    static let output = kAudioObjectPropertyScopeOutput

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = global) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func scalar<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                          _ initial: T, scope: AudioObjectPropertyScope = global) throws -> T {
        var a = address(selector, scope)
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutableBytes(of: &result) { bytes in
            AudioObjectGetPropertyData(id, &a, 0, nil, &size, bytes.baseAddress!)
        }
        try checkAudio(status, "Read property \(selector) on device \(id)")
        return result
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }

    static func array<T>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                         _ type: T.Type, scope: AudioObjectPropertyScope = global) throws -> [T] {
        var a = address(selector, scope)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "Read device property size")
        guard size > 0 else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { memory.deallocate() }
        try checkAudio(AudioObjectGetPropertyData(id, &a, 0, nil, &size, memory), "Read device property array")
        return Array(UnsafeBufferPointer(start: memory.assumingMemoryBound(to: T.self), count: Int(size) / MemoryLayout<T>.stride))
    }

    static func channels(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) throws -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size), "Read channel layout size")
        guard size >= MemoryLayout<UInt32>.size else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try checkAudio(AudioObjectGetPropertyData(id, &a, 0, nil, &size, memory), "Read channel layout")
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    static func streamLatency(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> UInt32 {
        let streams = (try? array(id, kAudioDevicePropertyStreams, AudioStreamID.self, scope: scope)) ?? []
        return streams.compactMap { try? scalar($0, kAudioStreamPropertyLatency, UInt32(0)) }.max() ?? 0
    }

    static func enumerate() throws -> [AudioEndpoint] {
        let ids = try array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, AudioDeviceID.self)
        return try ids.map { id in
            let range = try? scalar(id, kAudioDevicePropertyBufferFrameSizeRange, AudioValueRange())
            let rates = (try? array(id, kAudioDevicePropertyAvailableNominalSampleRates, AudioValueRange.self)) ?? []
            func u32(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32? {
                try? scalar(id, selector, UInt32(0), scope: scope)
            }
            return AudioEndpoint(
                id: id, uid: string(id, kAudioDevicePropertyDeviceUID) ?? "unavailable:\(id)",
                name: string(id, kAudioObjectPropertyName) ?? "Unnamed device \(id)",
                manufacturer: string(id, kAudioObjectPropertyManufacturer) ?? "Unknown",
                inputChannels: try channels(id, scope: input), outputChannels: try channels(id, scope: output),
                sampleRate: (try? scalar(id, kAudioDevicePropertyNominalSampleRate, Double(0))) ?? 0,
                bufferFrames: (try? scalar(id, kAudioDevicePropertyBufferFrameSize, UInt32(0))) ?? 0,
                bufferRange: range.map { UInt32(max(0, $0.mMinimum))...UInt32(max(0, $0.mMaximum)) },
                supportedRates: rates.map { $0.mMinimum == $0.mMaximum ? "\(Int($0.mMinimum))" : "\(Int($0.mMinimum))–\(Int($0.mMaximum))" }.joined(separator: ", "),
                alive: u32(kAudioDevicePropertyDeviceIsAlive, global) == 1,
                clockDomain: u32(kAudioDevicePropertyClockDomain, global) ?? 0,
                inputLatency: u32(kAudioDevicePropertyLatency, input) ?? 0,
                outputLatency: u32(kAudioDevicePropertyLatency, output) ?? 0,
                inputSafety: u32(kAudioDevicePropertySafetyOffset, input) ?? 0,
                outputSafety: u32(kAudioDevicePropertySafetyOffset, output) ?? 0,
                inputStreamLatency: streamLatency(id, scope: input), outputStreamLatency: streamLatency(id, scope: output),
                inputSource: u32(kAudioDevicePropertyDataSource, input), outputSource: u32(kAudioDevicePropertyDataSource, output),
                inputJack: u32(kAudioDevicePropertyJackIsConnected, input), outputJack: u32(kAudioDevicePropertyJackIsConnected, output))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func setBuffer(_ frames: UInt32, device: AudioEndpoint) throws {
        guard device.bufferFrames != frames else { return }
        var a = address(kAudioDevicePropertyBufferFrameSize)
        var settable: DarwinBoolean = false
        try checkAudio(AudioObjectIsPropertySettable(device.id, &a, &settable), "Check buffer control")
        guard settable.boolValue, device.bufferRange?.contains(frames) == true else {
            throw AudioFailure("\(device.name) cannot use \(frames) frames. Select ‘Keep hardware’ or a supported size.")
        }
        var value = frames
        try checkAudio(AudioObjectSetPropertyData(device.id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value), "Set buffer for \(device.name)")
        let actual = try scalar(device.id, kAudioDevicePropertyBufferFrameSize, UInt32(0))
        guard actual == frames else { throw AudioFailure("\(device.name) accepted \(actual), not the requested \(frames) frames. Select ‘Keep hardware’ to use it.") }
    }
}

// Notifications are delivered on the main queue. No listener touches audio buffers.
final class AudioDeviceWatcher {
    private var registrations: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    func watch(_ devices: [AudioEndpoint], onChange: @escaping () -> Void) {
        clear()
        add(AudioObjectID(kAudioObjectSystemObject), AudioDeviceManager.address(kAudioHardwarePropertyDevices), onChange)
        for device in devices {
            for selector in [kAudioDevicePropertyDeviceIsAlive, kAudioDevicePropertyNominalSampleRate, kAudioDevicePropertyBufferFrameSize] {
                add(device.id, AudioDeviceManager.address(selector), onChange)
            }
            for scope in [AudioDeviceManager.input, AudioDeviceManager.output] {
                for selector in [kAudioDevicePropertyDataSource, kAudioDevicePropertyJackIsConnected, kAudioDevicePropertyStreamConfiguration] {
                    add(device.id, AudioDeviceManager.address(selector, scope), onChange)
                }
            }
        }
    }
    private func add(_ id: AudioObjectID, _ property: AudioObjectPropertyAddress, _ onChange: @escaping () -> Void) {
        var a = property
        guard AudioObjectHasProperty(id, &a) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        if AudioObjectAddPropertyListenerBlock(id, &a, .main, block) == noErr { registrations.append((id, a, block)) }
    }
    func clear() {
        for (id, property, block) in registrations {
            var a = property
            AudioObjectRemovePropertyListenerBlock(id, &a, .main, block)
        }
        registrations.removeAll()
    }
    deinit { clear() }
}
