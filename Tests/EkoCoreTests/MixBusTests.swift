import AVFoundation
import Testing
@testable import EkoCore

struct MixBusTests {
    private func buffer(_ samples: [Float], channels: Int, rate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(channels))!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        for c in 0..<channels { for i in 0..<samples.count { b.floatChannelData![c][i] = samples[i] } }
        b.frameLength = AVAudioFrameCount(samples.count)
        return b
    }

    @Test func alignsSystemAudioToMicTimelineAndFillsSilenceWhenAbsent() throws {
        let bus = MixBus(sampleRate: 48_000, ringSeconds: 1)
        let t0 = HostClock.now()
        var clock = t0
        bus.now = { clock }
        var output: [[Float]] = [[], []]
        bus.onOutput = { out in
            for c in 0..<2 { output[c] += Array(UnsafeBufferPointer(start: out.floatChannelData![c], count: Int(out.frameLength))) }
        }
        let tick = HostClock.ticks(seconds: 0.01) // 480 frames

        // 20 ms of mic at 0.1, then 10 ms at 0.2; system audio only for the second 10 ms, at 0.5.
        bus.pushMic(buffer([Float](repeating: 0.1, count: 480), channels: 1), hostTime: t0)
        bus.pushMic(buffer([Float](repeating: 0.1, count: 480), channels: 1), hostTime: t0 + tick)
        bus.pushMic(buffer([Float](repeating: 0.2, count: 480), channels: 1), hostTime: t0 + 2 * tick)
        bus.pushSystem(buffer([Float](repeating: 0.5, count: 480), channels: 2), hostTime: t0 + 2 * tick)
        clock = t0 + 10 * tick
        bus.finish()

        #expect(output[0].count == 1440)
        #expect(abs(output[0][0] - 0.1) < 1e-6)       // mic only
        #expect(abs(output[1][959] - 0.1) < 1e-6)     // still mic only right before system audio
        #expect(abs(output[0][960] - 0.7) < 1e-6)     // mic 0.2 + system 0.5
        #expect(abs(output[1][1439] - 0.7) < 1e-6)
        #expect(bus.framesMixed == 1440)
    }

    @Test func lateSystemAudioAfterMixIsDroppedNotReplayed() throws {
        let bus = MixBus(sampleRate: 48_000, ringSeconds: 1)
        let t0 = HostClock.now()
        var clock = t0
        bus.now = { clock }
        var peak: Float = 0
        bus.onOutput = { out in
            for i in 0..<Int(out.frameLength) { peak = max(peak, abs(out.floatChannelData![0][i])) }
        }
        let tick = HostClock.ticks(seconds: 0.01)
        bus.pushMic(buffer([Float](repeating: 0, count: 480), channels: 1), hostTime: t0)
        clock = t0 + 100 * tick
        bus.finish()                      // mic frames 0..<480 are mixed now
        bus.pushSystem(buffer([Float](repeating: 0.9, count: 480), channels: 2), hostTime: t0) // too late
        bus.pushMic(buffer([Float](repeating: 0, count: 480), channels: 1), hostTime: t0 + tick)
        clock = t0 + 200 * tick
        bus.finish()
        #expect(peak == 0)
    }

    @Test func namerSanitizesAndAvoidsCollisions() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("eko-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let date = Date(timeIntervalSince1970: 1_761_750_300)
        let first = RecordingNamer.url(in: dir, date: date, app: "Zoom: Weekly/Sync", ext: "m4a")
        #expect(first.lastPathComponent.hasSuffix(" Zoom Weekly Sync.m4a"))
        FileManager.default.createFile(atPath: first.path, contents: Data())
        let second = RecordingNamer.url(in: dir, date: date, app: "Zoom: Weekly/Sync", ext: "m4a")
        #expect(second.lastPathComponent.hasSuffix(" Zoom Weekly Sync (2).m4a"))
    }
}

struct KnownAppsTests {
    @Test func matchesHelperProcessesOfKnownApps() {
        #expect(KnownApps.name(forBundleID: "com.google.Chrome") == "Chrome")
        #expect(KnownApps.name(forBundleID: "com.google.Chrome.helper") == "Chrome")
        #expect(KnownApps.name(forBundleID: "us.zoom.xos") == "Zoom")
        #expect(KnownApps.name(forBundleID: "com.apple.Music") == nil)
    }
}

struct VersionNumberTests {
    @Test func comparesNumericallyAndIgnoresDecorations() {
        #expect(VersionNumber.isNewer("0.10.0", than: "0.9.1"))
        #expect(VersionNumber.isNewer("v1.0", than: "0.9.9"))
        #expect(VersionNumber.isNewer("1.0.1", than: "1.0"))
        #expect(!VersionNumber.isNewer("1.0", than: "1.0.0"))
        #expect(!VersionNumber.isNewer("0.1.0", than: "0.1.1"))
        #expect(VersionNumber.isNewer("2.0.0-beta", than: "1.9"))
    }
}
