import AudioToolbox
import CoreAudio

final class HALUnit {
    let unit: AudioUnit
    let capture: Bool
    let channels: UInt32
    let rate: Double
    let maxFrames: UInt32 = 4096
    private var initialized = false
    private var started = false
    private(set) var disposed = false

    init(device: AudioEndpoint, capture: Bool) throws {
        self.capture = capture
        channels = UInt32(capture ? device.inputChannels : device.outputChannels)
        rate = device.sampleRate
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput, componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else { throw AudioFailure("Apple AUHAL component unavailable.") }
        var instance: AudioUnit?
        try checkAudio(AudioComponentInstanceNew(component, &instance), "Create AUHAL")
        guard let instance else { throw AudioFailure("AUHAL returned no instance.") }
        unit = instance
        do {
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Input, bus: 1, value: UInt32(capture ? 1 : 0))
            try set(kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, bus: 0, value: UInt32(capture ? 0 : 1))
            try set(kAudioOutputUnitProperty_CurrentDevice, scope: kAudioUnitScope_Global, bus: 0, value: device.id)
            var actualDevice: AudioDeviceID = 0
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            try checkAudio(AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &actualDevice, &size), "Verify AUHAL device binding")
            guard actualDevice == device.id else { throw AudioFailure("AUHAL did not bind the selected device.") }
            let format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
                mBitsPerChannel: 32, mReserved: 0)
            try set(kAudioUnitProperty_StreamFormat, scope: capture ? kAudioUnitScope_Output : kAudioUnitScope_Input,
                    bus: capture ? 1 : 0, value: format)
            var accepted = AudioStreamBasicDescription()
            var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try checkAudio(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                capture ? kAudioUnitScope_Output : kAudioUnitScope_Input, capture ? 1 : 0,
                &accepted, &formatSize), "Read back AUHAL client format")
            guard accepted.mSampleRate == format.mSampleRate,
                  accepted.mFormatID == format.mFormatID, accepted.mFormatFlags == format.mFormatFlags,
                  accepted.mChannelsPerFrame == format.mChannelsPerFrame,
                  accepted.mBytesPerFrame == 4, accepted.mBytesPerPacket == 4,
                  accepted.mFramesPerPacket == 1, accepted.mBitsPerChannel == 32 else {
                throw AudioFailure("AUHAL did not accept the requested noninterleaved Float32 client format for \(device.name).")
            }
            try set(kAudioUnitProperty_MaximumFramesPerSlice, scope: kAudioUnitScope_Global, bus: 0, value: maxFrames)
            if capture {
                try set(kAudioUnitProperty_ShouldAllocateBuffer, scope: kAudioUnitScope_Output, bus: 1, value: UInt32(0))
            }
        } catch {
            AudioComponentInstanceDispose(unit)
            disposed = true
            throw error
        }
    }

    private func set<T>(_ property: AudioUnitPropertyID, scope: AudioUnitScope, bus: AudioUnitElement, value: T) throws {
        var value = value
        let status = withUnsafeBytes(of: &value) { bytes in
            AudioUnitSetProperty(unit, property, scope, bus, bytes.baseAddress!, UInt32(bytes.count))
        }
        try checkAudio(status, "Configure AUHAL property \(property)")
    }

    func attach(context: UnsafeMutableRawPointer) throws {
        let callback = DeckMakeCallback(capture, context)
        try set(capture ? kAudioOutputUnitProperty_SetInputCallback : kAudioUnitProperty_SetRenderCallback,
                scope: capture ? kAudioUnitScope_Global : kAudioUnitScope_Input, bus: 0, value: callback)
        try checkAudio(AudioUnitInitialize(unit), "Initialize selected AUHAL")
        initialized = true
    }
    func start() throws { try checkAudio(AudioOutputUnitStart(unit), "Start selected AUHAL"); started = true }
    func stop() -> OSStatus {
        var result: OSStatus = noErr
        if started { result = AudioOutputUnitStop(unit); started = false }
        if initialized {
            let status = AudioUnitUninitialize(unit)
            if result == noErr { result = status }
            initialized = false
        }
        return result
    }
    func close() -> OSStatus {
        guard !disposed else { return noErr }
        let stopped = stop()
        let released = AudioComponentInstanceDispose(unit)
        disposed = released == noErr
        return released != noErr ? released : stopped
    }
    deinit { _ = close() }
}
