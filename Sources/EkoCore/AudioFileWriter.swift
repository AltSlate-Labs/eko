import AVFoundation
import Foundation

public enum OutputFormat: String, CaseIterable {
    case aac
    case wav

    public var fileExtension: String { self == .aac ? "m4a" : "wav" }

    func settings(sampleRate: Double, bitRate: Int) -> [String: Any] {
        switch self {
        case .aac:
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: bitRate,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        case .wav:
            return [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }
}

/// Serial writer that accepts stereo float32 buffers at any sample rate and
/// writes them to one file at the target sample rate, encoding as it goes.
public final class AudioFileWriter {
    public let url: URL
    public let targetFormat: AVAudioFormat
    public private(set) var framesWritten: AVAudioFramePosition = 0

    private var file: AVAudioFile?
    private let queue = DispatchQueue(label: "eko.writer", qos: .userInitiated)
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var lastError: Error?

    public init(url: URL, format: OutputFormat, sampleRate: Double = 48_000, bitRate: Int = 160_000) throws {
        self.url = url
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings(sampleRate: sampleRate, bitRate: bitRate),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        self.file = file
        self.targetFormat = file.processingFormat
    }

    /// Formats a buffer should use so that it can be written without conversion
    /// when the capture sample rate matches the file.
    public func inputFormat(sampleRate: Double) -> AVAudioFormat {
        if sampleRate == targetFormat.sampleRate { return targetFormat }
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
    }

    public func enqueue(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in write(buffer) }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file else { return }
        do {
            if buffer.format == targetFormat {
                try file.write(from: buffer)
                framesWritten += AVAudioFramePosition(buffer.frameLength)
                return
            }
            if converter == nil || converterInputFormat != buffer.format {
                converter = AVAudioConverter(from: buffer.format, to: targetFormat)
                converterInputFormat = buffer.format
            }
            guard let converter else { return }
            let ratio = targetFormat.sampleRate / buffer.format.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let error { throw error }
            if status != .error, out.frameLength > 0 {
                try file.write(from: out)
                framesWritten += AVAudioFramePosition(out.frameLength)
            }
        } catch {
            lastError = error
        }
    }

    /// Flushes pending buffers and finalises the file. Returns the first write error, if any.
    public func finish() -> Error? {
        queue.sync {
            if #available(macOS 15.0, *) { file?.close() }
            file = nil
            converter = nil
        }
        return lastError
    }

    public var durationSeconds: Double { Double(framesWritten) / targetFormat.sampleRate }
}
