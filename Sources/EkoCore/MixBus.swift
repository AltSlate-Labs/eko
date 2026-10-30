import AVFoundation
import Foundation

/// Time-aligned software mixer.
///
/// The microphone stream defines the recording timeline (it always runs). System audio is
/// placed into a ring buffer by absolute sample position derived from HAL host timestamps,
/// so it lines up with the mic even though it arrives from a different device that may start
/// late, pause, or restart. Each stream is placed contiguously once anchored and re-anchored
/// only when its timestamps jump. Output is stereo float at `sampleRate`, delivered after a
/// short latency so that system audio for the same instant has had time to arrive.
public final class MixBus {
    public let sampleRate: Double
    public let format: AVAudioFormat
    public var micGain: Float = 1
    public var systemGain: Float = 1
    public var latencySeconds: Double = 0.3
    /// Injectable clock (tests).
    public var now: () -> UInt64 = { HostClock.now() }
    public var onOutput: ((AVAudioPCMBuffer) -> Void)?
    public var onNotice: ((String) -> Void)?

    public struct Levels { public var mic: Float = 0; public var system: Float = 0; public init() {} }
    public private(set) var levels = Levels()
    public private(set) var framesMixed: Int64 = 0
    public private(set) var systemFramesReceived: Int64 = 0
    public private(set) var micFramesReceived: Int64 = 0

    private let queue = DispatchQueue(label: "eko.mix", qos: .userInitiated)
    private var epochHost: UInt64?
    private var micSamples: [Float] = []
    private var micHead: Int64 = 0
    private var micNext: Int64?
    private var ringL: [Float]
    private var ringR: [Float]
    private let ringFrames: Int
    private var sysNext: Int64?
    private var micConverter: RateConverter?
    private var sysConverter: RateConverter?
    private let chunkFrames = 4096
    private let jumpTolerance: Int64

    public init(sampleRate: Double = 48_000, ringSeconds: Double = 30) {
        self.sampleRate = sampleRate
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        ringFrames = Int(sampleRate * ringSeconds)
        ringL = [Float](repeating: 0, count: ringFrames)
        ringR = [Float](repeating: 0, count: ringFrames)
        jumpTolerance = Int64(sampleRate * 0.05)
    }

    // MARK: Input

    public func pushMic(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        queue.async { [self] in
            guard let converted = convertMic(buffer) else { return }
            ingestMic(converted, hostTime: hostTime)
            drain(final: false)
        }
    }

    public func pushSystem(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        queue.async { [self] in
            guard let converted = convertSystem(buffer) else { return }
            ingestSystem(converted, hostTime: hostTime)
        }
    }

    /// Mixes everything received so far, ignoring the latency window.
    public func finish() {
        queue.sync { drain(final: true) }
    }

    // MARK: Internals (all on `queue`)

    private func convertMic(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.sampleRate == sampleRate && buffer.format.channelCount == 1 { return buffer }
        let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        if micConverter == nil || micConverter?.inputFormat != buffer.format { micConverter = RateConverter(from: buffer.format, to: target) }
        return micConverter?.convert(buffer)
    }

    private func convertSystem(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if sysConverter == nil || sysConverter?.inputFormat != buffer.format { sysConverter = RateConverter(from: buffer.format, to: format) }
        return sysConverter?.convert(buffer)
    }

    private func absoluteIndex(forHost host: UInt64) -> Int64 {
        if epochHost == nil { epochHost = host }
        let seconds = HostClock.seconds(host) - HostClock.seconds(epochHost!)
        return Int64((seconds * sampleRate).rounded())
    }

    private func placement(next: Int64?, host: UInt64, label: String) -> Int64 {
        let fromClock = absoluteIndex(forHost: host)
        guard let next else { return fromClock }
        if abs(next - fromClock) > jumpTolerance {
            onNotice?(String(format: "%@ stream timestamps jumped %.2f s; re-anchoring", label, Double(fromClock - next) / sampleRate))
            return fromClock
        }
        return next
    }

    private func ingestMic(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let n = Int(buffer.frameLength)
        guard n > 0, let src = buffer.floatChannelData?[0] else { return }
        micFramesReceived += Int64(n)
        var start = placement(next: micNext, host: hostTime, label: "mic")
        var offset = 0
        if micSamples.isEmpty {
            micHead = max(start, micHead)
            start = micHead
        } else {
            let end = micHead + Int64(micSamples.count)
            if start > end {
                micSamples.append(contentsOf: repeatElement(0, count: Int(min(start - end, Int64(sampleRate * 5)))))
            } else if start < end {
                offset = Int(min(end - start, Int64(n)))
            }
            start = end
        }
        var peak: Float = 0
        micSamples.reserveCapacity(micSamples.count + n - offset)
        for i in offset..<n {
            let s = src[i] * micGain
            peak = max(peak, abs(s))
            micSamples.append(s)
        }
        levels.mic = peak
        micNext = start + Int64(n - offset)
    }

    private func ingestSystem(_ buffer: AVAudioPCMBuffer, hostTime: UInt64) {
        let n = Int(buffer.frameLength)
        guard n > 0, let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] else { return }
        systemFramesReceived += Int64(n)
        let start = placement(next: sysNext, host: hostTime, label: "system")
        sysNext = start + Int64(n)
        let lowest = micHead                      // anything earlier has already been mixed
        let highest = micHead + Int64(ringFrames) // anything later does not fit the ring
        var peak: Float = 0
        for i in 0..<n {
            let position = start + Int64(i)
            guard position >= lowest, position < highest else { continue }
            let slot = Int(position % Int64(ringFrames))
            let l = left[i] * systemGain, r = right[i] * systemGain
            peak = max(peak, abs(l), abs(r))
            ringL[slot] = l
            ringR[slot] = r
        }
        levels.system = peak
    }

    private func drain(final: Bool) {
        guard !micSamples.isEmpty else { return }
        let limit = final ? micHead + Int64(micSamples.count) : absoluteIndex(forHost: now()) - Int64(latencySeconds * sampleRate)
        var remaining = Int(min(Int64(micSamples.count), limit - micHead))
        guard remaining > 0 else { return }
        var consumed = 0
        while remaining > 0 {
            let n = min(chunkFrames, remaining)
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { return }
            let outL = out.floatChannelData![0], outR = out.floatChannelData![1]
            for i in 0..<n {
                let position = micHead + Int64(consumed + i)
                let slot = Int(position % Int64(ringFrames))
                let m = micSamples[consumed + i]
                outL[i] = min(1, max(-1, ringL[slot] + m))
                outR[i] = min(1, max(-1, ringR[slot] + m))
                ringL[slot] = 0
                ringR[slot] = 0
            }
            out.frameLength = AVAudioFrameCount(n)
            onOutput?(out)
            framesMixed += Int64(n)
            consumed += n
            remaining -= n
        }
        micSamples.removeFirst(consumed)
        micHead += Int64(consumed)
    }
}

/// Small wrapper around AVAudioConverter for chunk-by-chunk sample-rate/channel conversion.
final class RateConverter {
    let inputFormat: AVAudioFormat
    let outputFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(from input: AVAudioFormat, to output: AVAudioFormat) {
        inputFormat = input
        outputFormat = output
        converter = AVAudioConverter(from: input, to: output)
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .noDataNow; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        return status == .error ? nil : out
    }
}
