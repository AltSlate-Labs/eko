import AVFoundation
import Foundation

/// A recording's loudness outline for the player's scrubber: `bins` values in 0…1 (both channels combined).
public enum Waveform {
    public static func envelope(of url: URL, bins: Int = 160) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        guard total > 0, bins > 0 else { return [] }
        let format = file.processingFormat
        let perBin = max(1, Int(total) / bins)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(min(perBin, 1 << 20)))!
        // Average loudness (RMS) per bar, not the peak: peaks are near full scale all through a call, so a
        // peak outline looks flat; RMS shows pauses and quiet stretches.
        var energy = [Double](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        var frame = 0
        while file.framePosition < total {
            try file.read(into: buffer)
            let n = Int(buffer.frameLength)
            if n == 0 { break }
            guard let channels = buffer.floatChannelData else { break }
            for c in 0..<Int(format.channelCount) {
                let data = channels[c]
                for i in 0..<n {
                    let bin = min(bins - 1, (frame + i) / perBin)
                    energy[bin] += Double(data[i] * data[i])
                    counts[bin] += 1
                }
            }
            frame += n
        }
        let rms = zip(energy, counts).map { $1 == 0 ? 0 : Float(($0 / Double($1)).squareRoot()) }
        let top = rms.max() ?? 0
        guard top > 0 else { return rms }
        return rms.map { pow($0 / top, 0.8) }
    }
}
