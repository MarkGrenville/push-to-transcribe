import AVFoundation
import AudioToolbox
import CoreAudio

/// Captures from one specific physical input device through an input-only
/// AUHAL unit.
///
/// This replaces `AVAudioEngine`, whose input on macOS runs through a private
/// `CADefaultDeviceAggregate` that the system builds around the default
/// devices. When a mic was replugged or reset, that aggregate went stale inside
/// the process: every new engine — even a freshly constructed one — reported
/// the dead device's format and failed to start with `'!dev'` until the app was
/// relaunched. Binding a unit to a concrete `AudioDeviceID` sidesteps the
/// aggregate entirely, and when the device goes away we simply build a new
/// unit for whatever the default is now.
final class InputDeviceCapture {
    let deviceID: AudioObjectID
    let deviceName: String
    /// Format delivered to `onBuffer`: float32, non-interleaved, at the
    /// device's own rate and channel count.
    let format: AVAudioFormat

    private var unit: AudioUnit
    private let buffer: AVAudioPCMBuffer
    private let onBuffer: (AVAudioPCMBuffer) -> Void

    private let stateLock = NSLock()
    private var running = false
    private var framesDelivered = 0
    private var lastDeliveryAt = Date.distantPast
    private var startedAt = Date.distantPast
    private var lastRenderStatus: OSStatus = noErr

    /// Builds and initialises the unit. Does not open the microphone; only
    /// `start()` does.
    init(deviceID: AudioObjectID, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) throws {
        self.deviceID = deviceID
        self.deviceName = AudioDevices.name(of: deviceID)
        self.onBuffer = onBuffer

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.status("find HAL unit", kAudioUnitErr_InvalidElement)
        }
        var made: AudioUnit?
        try check(AudioComponentInstanceNew(component, &made), "create HAL unit")
        guard let unit = made else { throw CaptureError.status("create HAL unit", kAudioUnitErr_FailedInitialization) }
        self.unit = unit

        do {
            // Bus 1 is the input side of an AUHAL, bus 0 the output side.
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                           &enable, UInt32(MemoryLayout<UInt32>.size)), "enable input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                           &disable, UInt32(MemoryLayout<UInt32>.size)), "disable output")

            var device = deviceID
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &device, UInt32(MemoryLayout<AudioObjectID>.size)), "bind device")

            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                           &hardware, &size), "read device format")
            guard hardware.mSampleRate > 0, hardware.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: hardware.mSampleRate,
                                             channels: hardware.mChannelsPerFrame,
                                             interleaved: false) else {
                throw CaptureError.noInput
            }
            self.format = format

            var client = format.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                           &client, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "set client format")

            var maxFrames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, &size)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(maxFrames, 8192)) else {
                throw CaptureError.noInput
            }
            self.buffer = buffer
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timestamp, bus, frames, _ in
                Unmanaged<InputDeviceCapture>.fromOpaque(refCon)
                    .takeUnretainedValue()
                    .render(flags: flags, timestamp: timestamp, bus: bus, frames: frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        // Every stored property is set by now, so a throw from here runs
        // `deinit`, which disposes the unit.
        try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                       &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set input callback")
        try check(AudioUnitInitialize(unit), "initialise unit")
    }

    deinit {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Opens the microphone.
    func start() throws {
        try check(AudioOutputUnitStart(unit), "start \(deviceName)")
        stateLock.lock()
        running = true
        startedAt = Date()
        framesDelivered = 0
        lastDeliveryAt = Date.distantPast
        lastRenderStatus = noErr
        stateLock.unlock()
    }

    /// Releases the microphone. Synchronous: no callback runs after it returns.
    func stop() {
        AudioOutputUnitStop(unit)
        stateLock.lock()
        running = false
        stateLock.unlock()
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// Seconds the unit has been running without delivering anything — either
    /// since start, or since the last block. Zero while stopped.
    var secondsSinceAudio: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard running else { return 0 }
        let reference = framesDelivered > 0 ? lastDeliveryAt : startedAt
        return Date().timeIntervalSince(reference)
    }

    /// The most recent render failure since start, for logging a stall.
    var lastRenderError: OSStatus? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastRenderStatus == noErr ? nil : lastRenderStatus
    }

    /// The device still exists and still has the format the unit was built for.
    var matchesDevice: Bool {
        guard AudioDevices.isAlive(deviceID),
              let current = AudioDevices.inputFormat(of: deviceID) else { return false }
        return current.sampleRate == format.sampleRate && current.channels == format.channelCount
    }

    /// Runs on the device's IO thread.
    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timestamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32,
                        frames: UInt32) -> OSStatus {
        guard frames <= buffer.frameCapacity else { return noErr }

        // Reading `mutableAudioBufferList` resets each `mDataByteSize` from
        // `frameLength`, so the length has to be set first — sizing the list by
        // hand and then reading it again hands the unit zero-byte buffers, and
        // every render fails with -50.
        buffer.frameLength = frames
        let list = buffer.mutableAudioBufferList
        let status = AudioUnitRender(unit, flags, timestamp, bus, frames, list)
        guard status == noErr else {
            stateLock.lock()
            lastRenderStatus = status
            stateLock.unlock()
            return status
        }

        stateLock.lock()
        framesDelivered += Int(frames)
        lastDeliveryAt = Date()
        stateLock.unlock()

        onBuffer(buffer)
        return noErr
    }

    enum CaptureError: LocalizedError {
        case status(String, OSStatus)
        case noInput

        var errorDescription: String? {
            switch self {
            case .status(let step, let status):
                return "\(step) failed: \(AudioDevices.describe(status))"
            case .noInput:
                return "device has no usable input stream"
            }
        }
    }
}

private func check(_ status: OSStatus, _ step: String) throws {
    guard status == noErr else { throw InputDeviceCapture.CaptureError.status(step, status) }
}

/// Thin wrappers over the Core Audio object API.
enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)
    // `kAudioObjectPropertyElementMain` needs macOS 12; its value is 0.
    private static let mainElement = AudioObjectPropertyElement(0)

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: mainElement)
    }

    static var defaultInputDevice: AudioObjectID? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id)
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func name(of device: AudioObjectID) -> String {
        var address = address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr,
              let value = name?.takeRetainedValue() else { return "device \(device)" }
        return value as String
    }

    static func isAlive(_ device: AudioObjectID) -> Bool {
        var address = address(kAudioDevicePropertyDeviceIsAlive)
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    static func inputFormat(of device: AudioObjectID) -> (sampleRate: Double, channels: UInt32)? {
        var rateAddress = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &rateAddress, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }

        var configAddress = address(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        size = 0
        guard AudioObjectGetPropertyDataSize(device, &configAddress, 0, nil, &size) == noErr, size > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(device, &configAddress, 0, nil, &size, list) == noErr else { return nil }
        let channels = UnsafeMutableAudioBufferListPointer(list).reduce(UInt32(0)) { $0 + $1.mNumberChannels }
        return (rate, channels)
    }

    /// OSStatus as its four-character code where it has one — `'!dev'` says a
    /// lot more in a log than 560227702.
    static func describe(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) {
            return "'\(String(decoding: bytes, as: UTF8.self))' (\(status))"
        }
        return "\(status)"
    }
}
