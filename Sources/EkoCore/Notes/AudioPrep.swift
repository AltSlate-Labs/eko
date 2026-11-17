import AVFoundation
import Foundation

/// What Eko knows about a recording from its `.json` sidecar.
public struct RecordingInfo {
    public var url: URL
    /// Left = microphone (You), right = call audio (Others): recordings from Eko 0.1.2 on.
    public var split: Bool
    public var start: Date?
    public var apps: [String]
    public var duration: TimeInterval?
    /// False when the recording has no readable sidecar (very old recordings, other files, or one being recorded).
    public var hasSidecar = false

    public static func read(_ url: URL) -> RecordingInfo {
        let sidecar = url.deletingPathExtension().appendingPathExtension("json")
        let parsed = (try? Data(contentsOf: sidecar)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let json = parsed ?? [:]
        let start = (json["start"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return RecordingInfo(url: url, split: json["channels"] as? String == MixBus.channelLayout, start: start,
                             apps: json["appsHeard"] as? [String] ?? [],
                             duration: (json["durationSeconds"] as? NSNumber)?.doubleValue, hasSidecar: parsed != nil)
    }

    /// "2026-11-13 11:23", from the sidecar, else from the file's creation date.
    public var dateText: String {
        let date = start ?? (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

/// One side of a call, or one piece of a long side, ready to send: mono 16 kHz AAC.
public struct AudioPart: Equatable {
    public var file: URL
    public var speaker: Speaker
    /// Where this piece starts in the recording.
    public var offset: TimeInterval
    public var duration: TimeInterval
}

public struct PreparedAudio {
    public var parts: [AudioPart]
    /// Sides that were silent for the whole call and were not prepared.
    public var silent: [Speaker]
    public var duration: TimeInterval
}

/// Decodes a recording and writes each side as mono 16 kHz AAC (~32 kbps, ~14 MB per hour), the smallest
/// format that keeps everything Gemini uses (it downsamples to 16 kHz). Long sides are cut at the quietest
/// half second before each boundary, so no word is split and no overlap needs de-duplicating.
public enum AudioPrep {
    public enum Side: Equatable {
        case channel(Int, Speaker)
        case mix(Speaker)
        var speaker: Speaker {
            switch self { case let .channel(_, s), let .mix(s): return s }
        }
    }

    public enum PrepError: LocalizedError {
        case unreadable(String), noChannel(Int), encoder(String)
        public var errorDescription: String? {
            switch self {
            case let .unreadable(detail): return "The recording could not be read: \(detail)"
            case let .noChannel(c): return "The recording has no channel \(c + 1)."
            case let .encoder(detail): return "Audio conversion failed: \(detail)"
            }
        }
    }

    public static let sampleRate: Double = 16_000
    public static let bitRate = 32_000
    /// −50 dBFS: below this for the whole call, a side is treated as silent.
    public static let silencePeak: Float = 0.003_16

    /// Sides for a recording: You/Others for split recordings, one unlabelled mix otherwise.
    public static func sides(for info: RecordingInfo, channelCount: Int) -> [Side] {
        info.split && channelCount >= 2 ? [.channel(0, .you), .channel(1, .others)] : [.mix(.unlabelled)]
    }

    public static func channelCount(of url: URL) throws -> Int {
        do { return Int(try AVAudioFile(forReading: url).processingFormat.channelCount) } catch {
            throw PrepError.unreadable(error.localizedDescription)
        }
    }

    /// `halve`: instead of chunking, cut once at the quietest moment in the middle third (used when a
    /// model's answer for a part was cut off).
    public static func prepare(_ source: URL, sides: [Side], chunkSeconds: TimeInterval, into dir: URL,
                               prefix: String = "part", halve: Bool = false) throws -> PreparedAudio {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: source) } catch { throw PrepError.unreadable(error.localizedDescription) }
        let format = file.processingFormat
        let rate = format.sampleRate
        let channels = Int(format.channelCount)
        for case let .channel(c, _) in sides where c >= channels { throw PrepError.noChannel(c) }
        let duration = Double(file.length) / rate
        let block = AVAudioFrameCount(rate)   // 1 s
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { throw PrepError.encoder("buffer") }

        // Pass 1: peak and 100 ms energy per side, to find silent sides and quiet cut points.
        let window = max(1, Int(rate / 10))
        var peaks = [Float](repeating: 0, count: sides.count)
        var energy = [[Float]](repeating: [], count: sides.count)
        var acc = [Float](repeating: 0, count: sides.count)
        var inWindow = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            let n = Int(buffer.frameLength)
            for i in 0..<n {
                for (k, side) in sides.enumerated() {
                    let v = sample(buffer, side, channels, i)
                    peaks[k] = max(peaks[k], abs(v))
                    acc[k] += v * v
                }
                inWindow += 1
                if inWindow == window {
                    for k in sides.indices { energy[k].append(acc[k]); acc[k] = 0 }
                    inWindow = 0
                }
            }
        }

        var silent: [Speaker] = []
        var active: [(index: Int, side: Side, cuts: [TimeInterval])] = []
        for (k, side) in sides.enumerated() {
            if peaks[k] < silencePeak { silent.append(side.speaker); continue }
            let cuts = halve ? [halfCut(energy: energy[k], duration: duration)] : cutPoints(energy: energy[k], duration: duration, chunk: chunkSeconds)
            active.append((k, side, cuts))
        }
        if active.isEmpty { return PreparedAudio(parts: [], silent: silent, duration: duration) }

        // Pass 2: per side, mono → 16 kHz → AAC, switching files at the cut points.
        file.framePosition = 0
        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        var writers = try active.map { try SideWriter(side: $0.side, cuts: $0.cuts, duration: duration, dir: dir,
                                                       prefix: prefix, mono: mono, target: target) }
        let monoBuffer = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: block)!
        var position: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            try file.read(into: buffer, frameCount: block)
            let n = Int(buffer.frameLength)
            for (w, entry) in active.enumerated() {
                let out = monoBuffer.floatChannelData![0]
                for i in 0..<n { out[i] = sample(buffer, entry.side, channels, i) }
                monoBuffer.frameLength = AVAudioFrameCount(n)
                try writers[w].write(monoBuffer, at: position, rate: rate)
            }
            position += AVAudioFramePosition(n)
        }
        var parts: [AudioPart] = []
        for w in writers.indices { parts += try writers[w].finish() }
        return PreparedAudio(parts: parts, silent: silent, duration: duration)
    }

    @inline(__always)
    private static func sample(_ b: AVAudioPCMBuffer, _ side: Side, _ channels: Int, _ i: Int) -> Float {
        let data = b.floatChannelData!
        switch side {
        case let .channel(c, _): return data[c][i]
        case .mix:
            if channels == 1 { return data[0][i] }
            var sum: Float = 0
            for c in 0..<channels { sum += data[c][i] }
            return sum / Float(channels)
        }
    }

    /// The middle of the quietest 500 ms between one third and two thirds of the way through.
    static func halfCut(energy: [Float], duration: TimeInterval) -> TimeInterval {
        quietest(energy: energy, from: duration / 3, to: duration * 2 / 3) ?? duration / 2
    }

    static func quietest(energy: [Float], from lo: TimeInterval, to hi: TimeInterval) -> TimeInterval? {
        let first = max(0, Int(lo * 10)), last = min(Int(hi * 10) - 5, energy.count - 5)
        guard first <= last else { return nil }
        var best = first, bestSum = Float.greatestFiniteMagnitude
        for i in first...last {
            let sum = energy[i] + energy[i + 1] + energy[i + 2] + energy[i + 3] + energy[i + 4]
            if sum < bestSum { bestSum = sum; best = i }
        }
        return (Double(best) + 2.5) / 10
    }

    /// Cut times (seconds) so that no piece is longer than `chunk`: each cut is the middle of the quietest
    /// 500 ms in the 3 minutes (at most half a chunk) before the boundary.
    static func cutPoints(energy: [Float], duration: TimeInterval, chunk: TimeInterval) -> [TimeInterval] {
        guard chunk > 0, duration > chunk else { return [] }
        var cuts: [TimeInterval] = []
        var start: TimeInterval = 0
        while duration - start > chunk {
            let target = start + chunk
            let lo = max(start + chunk / 2, target - 180)
            let cut = max(start + 1, quietest(energy: energy, from: lo, to: target) ?? target)
            cuts.append(cut)
            start = cut
        }
        return cuts
    }
}

/// Writes one side into one or more AAC files, switching at the cut points.
private struct SideWriter {
    let side: AudioPrep.Side
    let cuts: [TimeInterval]
    let duration: TimeInterval
    let dir: URL
    let prefix: String
    let target: AVAudioFormat
    let converter: AVAudioConverter
    var file: AVAudioFile?
    var piece = 0
    var parts: [AudioPart] = []

    init(side: AudioPrep.Side, cuts: [TimeInterval], duration: TimeInterval, dir: URL, prefix: String,
         mono: AVAudioFormat, target: AVAudioFormat) throws {
        self.side = side
        self.cuts = cuts
        self.duration = duration
        self.dir = dir
        self.prefix = prefix
        self.target = target
        guard let converter = AVAudioConverter(from: mono, to: target) else { throw AudioPrep.PrepError.encoder("converter") }
        self.converter = converter
        try open()
    }

    private var pieceStart: TimeInterval { piece == 0 ? 0 : cuts[piece - 1] }

    private mutating func open() throws {
        let name = side.speaker == .unlabelled ? "mix" : side.speaker.rawValue.lowercased()
        let url = dir.appendingPathComponent("\(prefix)-\(name)-\(piece + 1).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: AudioPrep.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: AudioPrep.bitRate,
        ]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch { throw AudioPrep.PrepError.encoder(error.localizedDescription) }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let end = piece < cuts.count ? cuts[piece] : duration
        parts.append(AudioPart(file: url, speaker: side.speaker, offset: pieceStart, duration: end - pieceStart))
    }

    /// Without closing, the AAC file has no index (`moov` atom) and is unreadable.
    private mutating func close() {
        if #available(macOS 15.0, *) { file?.close() }
        file = nil
    }

    mutating func write(_ buffer: AVAudioPCMBuffer, at position: AVAudioFramePosition, rate: Double) throws {
        var from = 0
        let n = Int(buffer.frameLength)
        while from < n {
            var to = n
            if piece < cuts.count {
                let cut = Int((cuts[piece] * rate).rounded()) - Int(position)   // relative to this buffer
                if cut <= from {               // reached the cut: start the next piece
                    close()
                    piece += 1
                    try open()
                    continue
                }
                if cut < n { to = cut }
            }
            try convert(buffer, from: from, count: to - from)
            from = to
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, from: Int, count: Int) throws {
        let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(count))!
        memcpy(slice.floatChannelData![0], buffer.floatChannelData![0] + from, count * MemoryLayout<Float>.size)
        slice.frameLength = AVAudioFrameCount(count)
        let capacity = AVAudioFrameCount(Double(count) * target.sampleRate / buffer.format.sampleRate) + 256
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed { inputStatus.pointee = .noDataNow; return nil }
            fed = true
            inputStatus.pointee = .haveData
            return slice
        }
        if status == .error || error != nil { throw AudioPrep.PrepError.encoder(error?.localizedDescription ?? "convert") }
        if out.frameLength > 0 {
            do { try file?.write(from: out) } catch { throw AudioPrep.PrepError.encoder(error.localizedDescription) }
        }
    }

    mutating func finish() throws -> [AudioPart] {
        close()
        return parts
    }
}
