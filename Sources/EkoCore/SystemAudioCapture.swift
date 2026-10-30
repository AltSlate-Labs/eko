import AVFoundation
import CoreAudio
import Foundation

/// Captures everything the system plays (except this process) through a Core Audio
/// process tap wrapped in a private aggregate device clocked by the default output device.
///
/// Important HAL behaviour (macOS 14.2–15.x): `AudioDeviceStart` on such a device does not
/// deliver any IO until some tapped application starts playing audio. Once running it keeps
/// running through silence. Callers must therefore never wait on this stream; the microphone
/// is captured separately and the two are aligned by host time (see `MixBus`).
public final class SystemAudioCapture {
    public typealias Handler = (_ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

    public let outputDevice: AudioDevice
    public let sampleRate: Double
    public let tapChannels: Int
    public let format: AVAudioFormat
    public private(set) var callbackCount = 0

    private let tapDescription: CATapDescription
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var handler: Handler?
    private var tapBufferIndex = 0
    private let queue = DispatchQueue(label: "eko.tap", qos: .userInteractive)

    public init(outputDevice: AudioDevice, excludedPIDs: [pid_t]) throws {
        self.outputDevice = outputDevice
        let excluded = excludedPIDs.compactMap { try? AudioObjectID.processObject(forPID: $0) }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.uuid = UUID()
        description.muteBehavior = .unmuted
        description.isPrivate = true
        // Do not set `name` or `isExclusive`: on macOS 15.5 that makes the aggregate never run.
        tapDescription = description

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap
        do {
            let tapFormat: AudioStreamBasicDescription = try tapID.read(kAudioTapPropertyFormat, initial: AudioStreamBasicDescription())
            tapChannels = max(1, Int(tapFormat.mChannelsPerFrame))
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "eko system audio",
                kAudioAggregateDeviceUIDKey: "com.altslate.eko.tap." + UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: outputDevice.uid,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputDevice.uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate), "AudioHardwareCreateAggregateDevice")
            aggregateID = aggregate
            let rate: Double = try aggregateID.read(kAudioDevicePropertyNominalSampleRate, initial: 0.0)
            sampleRate = rate > 0 ? rate : tapFormat.mSampleRate
            let inputs = try aggregateID.inputStreamChannelCounts()
            guard let last = inputs.last, last == tapChannels else {
                throw CaptureError.unexpectedLayout(aggregate: inputs, tapChannels: tapChannels)
            }
            tapBufferIndex = inputs.count - 1
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        } catch {
            if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    deinit { teardown() }

    public func start(_ handler: @escaping Handler) throws {
        guard procID == nil else { return }
        self.handler = handler
        let index = tapBufferIndex
        let channels = tapChannels
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, queue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self, let handler = self.handler else { return }
            self.callbackCount += 1
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard list.count > index, let data = list[index].mData?.assumingMemoryBound(to: Float.self) else { return }
            let frames = Int(list[index].mDataByteSize) / (MemoryLayout<Float>.size * channels)
            guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            let left = out.floatChannelData![0], right = out.floatChannelData![1]
            if channels >= 2 {
                for i in 0..<frames { left[i] = data[i * channels]; right[i] = data[i * channels + 1] }
            } else {
                for i in 0..<frames { left[i] = data[i]; right[i] = data[i] }
            }
            out.frameLength = AVAudioFrameCount(frames)
            handler(out, HostClock.hostTime(of: inputTime))
        }
        try check(status, "AudioDeviceCreateIOProcIDWithBlock (tap)")
        procID = proc
        try check(AudioDeviceStart(aggregateID, proc), "AudioDeviceStart (tap)")
    }

    public func stop() {
        guard let proc = procID else { return }
        AudioDeviceStop(aggregateID, proc)
        AudioDeviceDestroyIOProcID(aggregateID, proc)
        procID = nil
        handler = nil
    }

    private func teardown() {
        stop()
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = AudioObjectID(kAudioObjectUnknown) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID); tapID = AudioObjectID(kAudioObjectUnknown) }
    }

    /// Best-effort check of the "System Audio Recording Only" permission: re-writing the tap
    /// description fails with a permissions error when it is missing. nil = inconclusive.
    public func probeSystemAudioPermission() -> Bool? {
        var address = propertyAddress(kAudioTapPropertyDescription)
        var pointer = Unmanaged.passUnretained(tapDescription).toOpaque()
        let status = AudioObjectSetPropertyData(tapID, &address, 0, nil, UInt32(MemoryLayout<UnsafeMutableRawPointer>.size), &pointer)
        switch status {
        case noErr: return true
        case kAudioDevicePermissionsError: return false
        default: return nil
        }
    }

    public var summary: String { "system=\"\(outputDevice.name)\" tap \(tapChannels) ch @ \(Int(sampleRate)) Hz" }
}
