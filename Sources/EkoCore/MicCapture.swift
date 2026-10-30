import AVFoundation
import CoreAudio
import Foundation

/// Captures the microphone (any input device) directly, delivering mono float buffers
/// at the device's sample rate together with the HAL host time of their first frame.
/// Unlike a tap-based aggregate device this starts immediately.
public final class MicCapture {
    public typealias Handler = (_ buffer: AVAudioPCMBuffer, _ hostTime: UInt64) -> Void

    public let device: AudioDevice
    public let sampleRate: Double
    public let channelCounts: [Int]
    public let format: AVAudioFormat
    public private(set) var callbackCount = 0

    private var procID: AudioDeviceIOProcID?
    private var handler: Handler?
    private let queue = DispatchQueue(label: "eko.mic", qos: .userInteractive)

    public init(device: AudioDevice) throws {
        self.device = device
        channelCounts = try device.id.inputStreamChannelCounts()
        guard !channelCounts.isEmpty else { throw CaptureError.noInputDevice }
        let rate = device.nominalSampleRate
        sampleRate = rate > 0 ? rate : 48_000
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    deinit { stop() }

    public func start(_ handler: @escaping Handler) throws {
        guard procID == nil else { return }
        self.handler = handler
        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device.id, queue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self, let handler = self.handler else { return }
            self.callbackCount += 1
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard list.count > 0 else { return }
            let first = list[0]
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * max(1, Int(first.mNumberChannels)))
            guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            let dst = out.floatChannelData![0]
            for i in 0..<frames { dst[i] = 0 }
            var totalChannels = 0
            for buffer in list {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let channels = max(1, Int(buffer.mNumberChannels))
                let n = min(frames, Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels))
                for i in 0..<n {
                    var sum: Float = 0
                    for c in 0..<channels { sum += data[i * channels + c] }
                    dst[i] += sum
                }
                totalChannels += channels
            }
            if totalChannels > 1 {
                let scale = 1 / Float(totalChannels)
                for i in 0..<frames { dst[i] *= scale }
            }
            out.frameLength = AVAudioFrameCount(frames)
            handler(out, HostClock.hostTime(of: inputTime))
        }
        try check(status, "AudioDeviceCreateIOProcIDWithBlock (mic)")
        procID = proc
        try check(AudioDeviceStart(device.id, proc), "AudioDeviceStart (mic)")
    }

    public func stop() {
        guard let proc = procID else { return }
        AudioDeviceStop(device.id, proc)
        AudioDeviceDestroyIOProcID(device.id, proc)
        procID = nil
        handler = nil
    }

    public var summary: String { "mic=\"\(device.name)\" \(channelCounts.reduce(0, +)) ch @ \(Int(sampleRate)) Hz" }
}

public enum CaptureError: Error, CustomStringConvertible {
    case unexpectedLayout(aggregate: [Int], tapChannels: Int)
    case noInputDevice
    case noOutputDevice

    public var description: String {
        switch self {
        case let .unexpectedLayout(aggregate, tap):
            return "Unexpected aggregate device layout: input streams \(aggregate), expected a \(tap)-channel tap stream last"
        case .noInputDevice: return "No default input (microphone) device"
        case .noOutputDevice: return "No default output device"
        }
    }
}
