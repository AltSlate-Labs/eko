import AVFoundation
import Foundation
import Testing
@testable import EkoCore

/// Temporary folder removed at the end of each test.
final class TempDir {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("eko-tests-\(UUID().uuidString)", isDirectory: true)
    init() { try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    deinit { try? FileManager.default.removeItem(at: url) }
}

/// Writes a stereo AAC file: left and right are each either a 440 Hz tone or silence, with optional quiet gaps.
func makeRecording(_ url: URL, seconds: Double, left: Bool, right: Bool, quietAt: [Double] = [], split: Bool = true) throws {
    let rate = 48_000.0
    let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000]
    do {
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        let total = Int(seconds * rate)
        let block = 48_000
        var written = 0
        while written < total {
            let n = min(block, total - written)
            let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for i in 0..<n {
                let t = Double(written + i) / rate
                let quiet = quietAt.contains { abs($0 - t) < 0.5 }
                let v = quiet ? 0 : Float(sin(2 * .pi * 440 * t) * 0.3)
                b.floatChannelData![0][i] = left ? v : 0
                b.floatChannelData![1][i] = right ? v : 0
            }
            try file.write(from: b)
            written += n
        }
        if #available(macOS 15.0, *) { file.close() }
    }
    if split {
        let sidecar: [String: Any] = ["channels": "split-v1", "start": "2026-11-13T05:53:00Z", "appsHeard": ["Chrome"]]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: url.deletingPathExtension().appendingPathExtension("json"))
    }
}

struct AudioPrepTests {
    @Test func splitsSidesSkipsSilenceAndWritesMono16kAAC() throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("call.m4a")
        try makeRecording(rec, seconds: 6, left: true, right: false)
        let info = RecordingInfo.read(rec)
        #expect(info.split)
        #expect(info.apps == ["Chrome"])
        let out = tmp.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prepared = try AudioPrep.prepare(rec, sides: AudioPrep.sides(for: info, channelCount: 2), chunkSeconds: 2400, into: out)
        #expect(prepared.silent == [.others])
        #expect(prepared.parts.count == 1)
        let part = try #require(prepared.parts.first)
        #expect(part.speaker == .you)
        let f = try AVAudioFile(forReading: part.file)
        #expect(f.fileFormat.sampleRate == 16_000)
        #expect(f.fileFormat.channelCount == 1)
        #expect(abs(Double(f.length) / 16_000 - 6) < 0.2)
        #expect((try FileManager.default.attributesOfItem(atPath: part.file.path)[.posixPermissions] as? Int) == 0o600)
    }

    @Test func chunksLongSidesAtAQuietMoment() throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("long.m4a")
        try makeRecording(rec, seconds: 25, left: true, right: true, quietAt: [8.0, 17.0])
        let out = tmp.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let prepared = try AudioPrep.prepare(rec, sides: [.channel(0, .you)], chunkSeconds: 10, into: out)
        #expect(prepared.parts.count == 3)
        #expect(abs(prepared.parts[1].offset - 8.0) < 0.4)   // the quiet half second before the 10 s boundary
        #expect(abs(prepared.parts[2].offset - 17.0) < 0.4)
        let total = try prepared.parts.reduce(0.0) { $0 + Double(try AVAudioFile(forReading: $1.file).length) / 16_000 }
        #expect(abs(total - 25) < 0.3)
        for p in prepared.parts { #expect(p.duration <= 10.01) }
    }

    @Test func oldRecordingsBecomeOneUnlabelledMix() throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("old.m4a")
        try makeRecording(rec, seconds: 3, left: true, right: true, split: false)
        let info = RecordingInfo.read(rec)
        #expect(!info.split)
        #expect(AudioPrep.sides(for: info, channelCount: 2) == [.mix(.unlabelled)])
    }
}

/// Returns canned lines per side, recording what it was asked.
final class FakeSpeech: SpeechEngine {
    var info: EngineInfo { EngineInfo(name: "Fake", model: "f1", location: "test") }
    private let lock = NSLock()
    private var recorded: [AudioPart] = []
    /// Parts are transcribed in parallel, so the record is guarded.
    var calls: [AudioPart] { lock.withLock { recorded } }
    var failFirstWithMaxTokens = false
    /// Calls (1-based) answered with HTTP 503.
    var overloadedOnCalls: Set<Int> = []
    func transcribe(_ part: AudioPart, names: NamesList) async throws -> SpeechResult {
        let (fail, overloaded) = lock.withLock {
            recorded.append(part)
            defer { failFirstWithMaxTokens = false }
            return (failFirstWithMaxTokens, overloadedOnCalls.contains(recorded.count))
        }
        if fail { throw GeminiError.maxTokens }
        if overloaded { throw GeminiError.server(503) }
        let text = part.speaker == .you ? "[00:00:01] Hello from me\n[00:00:04] Theek hai" : "[00:02] Hi from them"
        return SpeechResult(segments: TranscriptText.parseModelOutput(text, speaker: part.speaker).segments,
                            usage: Usage(inputTokens: 10, outputTokens: 2), nonLatin: 0)
    }
}

final class FakeSummary: SummaryEngine {
    var info: EngineInfo { EngineInfo(name: "Fake", model: "s1", location: "test") }
    var prompts: [String] = []
    var error: Error?
    func summarise(prompt: String) async throws -> (text: String, usage: Usage) {
        prompts.append(prompt)
        if let error { throw error }
        return ("SUMMARY\nThey said hi. [00:00:02]\n\nACTION ITEMS\n- Reply [00:09:00]", Usage(inputTokens: 50, outputTokens: 5))
    }
}

struct NotesPipelineTests {
    /// Finished pieces go to a test folder, never ~/Library/Application Support/Eko.
    let cacheDir = TempDir()

    func pipeline(_ speech: FakeSpeech, _ summary: FakeSummary) -> NotesPipeline {
        var p = NotesPipeline(speech: speech, summary: summary, settings: NotesSettings(), names: NamesList(text: "me: Nirdesh"),
                              template: (SummaryPrompt.defaultTemplate, "built-in default"))
        p.log = { _ in }
        p.partCacheRoot = cacheDir.url
        return p
    }

    @Test func retryOnlySendsThePartsStillMissing() async throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("r.m4a")
        try makeRecording(rec, seconds: 4, left: true, right: true)
        let speech = FakeSpeech(), summary = FakeSummary()
        speech.overloadedOnCalls = [2]
        await #expect(throws: GeminiError.self) { try await pipeline(speech, summary).run(rec) }
        #expect(speech.calls.count == 2)
        let kept = try FileManager.default.contentsOfDirectory(at: cacheDir.url, includingPropertiesForKeys: nil)
        #expect(kept.count == 1)
        let piece = try #require(FileManager.default.contentsOfDirectory(at: kept[0], includingPropertiesForKeys: nil).first)
        #expect((try FileManager.default.attributesOfItem(atPath: piece.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: kept[0].path)[.posixPermissions] as? Int) == 0o700)

        let outcome = try await pipeline(speech, summary).run(rec)
        #expect(speech.calls.count == 3)   // only the part that failed
        #expect(speech.calls[2].speaker == speech.calls[1].speaker)
        #expect(outcome.transcribed)
        let transcript = try String(contentsOf: OutputFile.transcriptURL(for: rec), encoding: .utf8)
        #expect(transcript.contains("[00:00:01] You: Hello from me\n[00:00:02] Others: Hi from them\n[00:00:04] You: Theek hai"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: cacheDir.url.path).isEmpty)   // removed once written
    }

    @Test func changedRecordingDoesNotReuseParts() async throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("r.m4a")
        try makeRecording(rec, seconds: 4, left: true, right: true)
        let root = cacheDir.url
        let a = try #require(PartCache(root: root, recording: rec, chunkSeconds: 2400, model: "m"))
        let b = try #require(PartCache(root: root, recording: rec, chunkSeconds: 1800, model: "m"))
        let c = try #require(PartCache(root: root, recording: rec, chunkSeconds: 2400, model: "other"))
        #expect(Set([a.dir, b.dir, c.dir]).count == 3)
        let part = AudioPart(file: rec, speaker: .you, offset: 0, duration: 4)
        a.save(SpeechResult(segments: [Segment(start: 1, speaker: .you, text: "hi")], usage: Usage(), nonLatin: 0), for: part)
        #expect(a.load(part)?.segments.first?.text == "hi")
        #expect(b.load(part) == nil)
        PartCache.removeStale(root: root, now: Date().addingTimeInterval(PartCache.keepFor + 60))
        #expect(a.load(part) == nil)
    }

    @Test func endToEndWritesTranscriptAndSummary() async throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("2026-11-13 11-23 Chrome.m4a")
        try makeRecording(rec, seconds: 6, left: true, right: true)
        let speech = FakeSpeech(), summary = FakeSummary()
        var stages: [NotesPipeline.Progress] = []
        let outcome = try await pipeline(speech, summary).run(rec, options: .init(producer: "Eko test")) { stages.append($0) }
        #expect(outcome.summaryError == nil)
        #expect(speech.calls.map(\.speaker) == [.you, .others] || speech.calls.map(\.speaker) == [.others, .you])
        let transcript = try String(contentsOf: OutputFile.transcriptURL(for: rec), encoding: .utf8)
        #expect(transcript.contains("Speech-to-text: Fake f1 (test) · Eko test"))
        #expect(transcript.contains("[00:00:01] You: Hello from me\n[00:00:02] Others: Hi from them\n[00:00:04] You: Theek hai"))
        let summaryText = try String(contentsOf: OutputFile.summaryURL(for: rec), encoding: .utf8)
        #expect(summaryText.contains("Checks: 1 of 2 cited timestamps match a transcript line."))
        #expect(summary.prompts.first?.contains("You = Nirdesh") == true)
        #expect(stages.first == .preparing)
        #expect(stages.last == .summarising)
        let perms = try FileManager.default.attributesOfItem(atPath: OutputFile.summaryURL(for: rec).path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func failedSummaryKeepsTranscriptAndARerunOnlySummarises() async throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("c.m4a")
        try makeRecording(rec, seconds: 4, left: true, right: true)
        let speech = FakeSpeech(), summary = FakeSummary()
        summary.error = GeminiError.server(503)
        let first = try await pipeline(speech, summary).run(rec)
        #expect(first.summaryError != nil)
        #expect(FileManager.default.fileExists(atPath: OutputFile.transcriptURL(for: rec).path))
        #expect(!FileManager.default.fileExists(atPath: OutputFile.summaryURL(for: rec).path))
        summary.error = nil
        let calls = speech.calls.count
        let second = try await pipeline(speech, summary).run(rec)
        #expect(!second.transcribed)
        #expect(speech.calls.count == calls)   // no audio sent again
        #expect(second.summary != nil)
        await #expect(throws: NotesPipeline.JobError.self) { try await pipeline(speech, summary).run(rec) }   // both exist
    }

    @Test func cutOffAnswerIsRetriedInHalves() async throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("long.m4a")
        try makeRecording(rec, seconds: 150, left: true, right: false, quietAt: [60])
        let speech = FakeSpeech()
        speech.failFirstWithMaxTokens = true
        _ = try await pipeline(speech, FakeSummary()).run(rec)
        #expect(speech.calls.count == 3)   // the full side, then two halves
        let transcript = try String(contentsOf: OutputFile.transcriptURL(for: rec), encoding: .utf8)
        #expect(transcript.contains("Others side silent, not sent"))
        #expect(transcript.components(separatedBy: "Hello from me").count == 3)   // once per half
    }
}

struct NotesQueueTests {
    @Test func persistsRetriesPausesAndDropsMissingFiles() throws {
        let tmp = TempDir()
        let file = tmp.url.appendingPathComponent("q.json")
        let rec = tmp.url.appendingPathComponent("r.m4a")
        try Data([0]).write(to: rec)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let q = NotesQueue(url: file)
        q.enqueue(rec, now: t0)
        q.enqueue(tmp.url.appendingPathComponent("gone.m4a"), now: t0)
        #expect(q.nextDue(now: t0)?.path == rec.standardizedFileURL.path)
        #expect(q.jobs.count == 1)   // gone.m4a dropped

        #expect(q.retryLater(rec.path, error: "offline", now: t0))
        #expect(q.nextDue(now: t0) == nil)
        #expect(q.nextDue(now: t0.addingTimeInterval(899)) == nil)
        #expect(q.nextDue(now: t0.addingTimeInterval(901)) != nil)

        q.pause(until: t0.addingTimeInterval(3600), error: "quota")
        #expect(q.nextDue(now: t0.addingTimeInterval(100)) == nil)
        let reloaded = NotesQueue(url: file)
        #expect(reloaded.pausedUntil == t0.addingTimeInterval(3600))
        #expect(reloaded.jobs.first?.attempts == 1)
        #expect(reloaded.nextDue(now: t0.addingTimeInterval(3601)) != nil)

        reloaded.retryLater(rec.path, error: "offline", now: t0)   // 30 min
        reloaded.retryLater(rec.path, error: "offline", now: t0)   // after the quota reset
        let reset = GeminiClient.nextQuotaReset(after: t0)
        let wait = try #require(reloaded.jobs.first?.nextTryAt).timeIntervalSince(reset)
        #expect(NotesQueue.afterResetDelay.contains(wait))   // 10–30 min after the reset
        for _ in 0..<2 { reloaded.retryLater(rec.path, error: "offline", now: t0) }
        #expect(!reloaded.retryLater(rec.path, error: "offline", now: t0))
        #expect(reloaded.failedJobs.count == 1)
        reloaded.retryAll(now: t0)
        #expect(reloaded.nextDue(now: t0) != nil)
        reloaded.complete(rec.path)
        #expect(NotesQueue(url: file).jobs.isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
    }
}

struct NotesQueuePolicyTests {
    @Test func newestJobRunsFirst() throws {
        let tmp = TempDir()
        let q = NotesQueue(url: tmp.url.appendingPathComponent("q.json"))
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let old = tmp.url.appendingPathComponent("old.m4a"), new = tmp.url.appendingPathComponent("new.m4a")
        for f in [old, new] { try Data([0]).write(to: f) }
        q.enqueue(old, now: t0)
        q.enqueue(new, now: t0.addingTimeInterval(86_400))
        #expect(q.nextDue(now: t0.addingTimeInterval(86_400))?.url.lastPathComponent == "new.m4a")
    }

    @Test func overloadPausesWholeQueueLongerEachTimeUntilASuccess() throws {
        let tmp = TempDir()
        let file = tmp.url.appendingPathComponent("q.json")
        let a = tmp.url.appendingPathComponent("a.m4a"), b = tmp.url.appendingPathComponent("b.m4a")
        for f in [a, b] { try Data([0]).write(to: f) }
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let q = NotesQueue(url: file)
        q.enqueue(a, now: t0)
        q.enqueue(b, now: t0)
        var now = t0
        for expected in [1800.0, 3600, 7200, 14_400, 14_400] {
            q.pauseForOverload(error: "503", now: now)
            #expect(q.pausedForOverload)
            #expect(q.pausedUntil == now.addingTimeInterval(expected))
            #expect(q.nextDue(now: now.addingTimeInterval(expected - 1)) == nil)   // no job runs, not just this one
            now = now.addingTimeInterval(expected + 1)
            #expect(q.nextDue(now: now) != nil)
            #expect(!q.pausedForOverload)
        }
        #expect(q.jobs.allSatisfy { $0.attempts == 0 && !$0.failed })   // overloads do not count against jobs
        #expect(NotesQueue(url: file).overloadStreak == 5)                // survives a restart
        q.complete(a.path)
        q.pauseForOverload(error: "503", now: now)
        #expect(q.pausedUntil == now.addingTimeInterval(1800))           // back to 30 min after a success
    }

    @Test func quotaPauseEndsTenToThirtyMinutesAfterTheReset() throws {
        let tmp = TempDir()
        let q = NotesQueue(url: tmp.url.appendingPathComponent("q.json"))
        let reset = Date(timeIntervalSince1970: 2_000_000)
        for _ in 0..<20 {
            q.pause(untilReset: reset, error: "quota")
            #expect(NotesQueue.afterResetDelay.contains(try #require(q.pausedUntil).timeIntervalSince(reset)))
            #expect(!q.pausedForOverload)
        }
    }

    @Test func networkErrorsNeverUseUpTries() throws {
        let tmp = TempDir()
        let q = NotesQueue(url: tmp.url.appendingPathComponent("q.json"))
        let rec = tmp.url.appendingPathComponent("r.m4a")
        try Data([0]).write(to: rec)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        q.enqueue(rec, now: t0)
        for _ in 0..<20 { q.retryAfterNetworkError(rec.path, error: "timed out", now: t0) }
        let job = try #require(q.jobs.first)
        #expect(job.attempts == 0 && !job.failed)
        #expect(job.nextTryAt == t0.addingTimeInterval(900))
    }
}

struct OutputFileTests {
    @Test func namesAtomicWriteAndNoOverwrite() throws {
        let tmp = TempDir()
        let rec = tmp.url.appendingPathComponent("2026-11-13 11-23 Chrome.m4a")
        let t = OutputFile.transcriptURL(for: rec)
        #expect(t.lastPathComponent == "2026-11-13 11-23 Chrome-transcript.txt")
        #expect(OutputFile.summaryURL(for: rec).lastPathComponent == "2026-11-13 11-23 Chrome-summary.txt")
        try OutputFile.write("one", to: t, overwrite: false)
        #expect(throws: OutputFile.WriteError.exists(t.lastPathComponent)) { try OutputFile.write("two", to: t, overwrite: false) }
        #expect(try String(contentsOf: t, encoding: .utf8) == "one")
        try OutputFile.write("three", to: t, overwrite: true)
        #expect(try String(contentsOf: t, encoding: .utf8) == "three")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }
}
