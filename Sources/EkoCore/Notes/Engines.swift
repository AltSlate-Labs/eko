import Foundation

/// Who produced a transcript or summary; goes into the file headers.
public struct EngineInfo: Equatable {
    public var name: String
    public var model: String
    public var location: String
    public init(name: String, model: String, location: String) {
        self.name = name
        self.model = model
        self.location = location
    }
    public var label: String { "\(name) \(model)" }
}

public struct SpeechResult {
    /// Times relative to the start of the part.
    public var segments: [Segment]
    public var usage: Usage
    /// Share of non-Latin letters left after any retry (0 = Roman script only).
    public var nonLatin: Double
}

/// Seam 1: speech-to-text. Gemini now; Hex or whisper.cpp later (PLAN-CALL-NOTES.md) without pipeline changes.
public protocol SpeechEngine {
    var info: EngineInfo { get }
    func transcribe(_ part: AudioPart, names: NamesList) async throws -> SpeechResult
}

/// Seam 2: summary from transcript text.
public protocol SummaryEngine {
    var info: EngineInfo { get }
    func summarise(prompt: String) async throws -> (text: String, usage: Usage)
}

public enum TranscriptionPrompt {
    static let base = """
    Transcribe this audio verbatim. It is one side of a business call; speech mixes Hindi and English.
    Write EVERYTHING in Roman (Latin) script: English words in normal English spelling, Hindi words in common \
    everyday Hinglish romanisation (e.g. nahi, yaar, accha, theek hai). Never use Devanagari or any other script.
    Do not translate, summarise, clean up or skip anything. Skip silence.
    Output one line per utterance in the form [HH:MM:SS] text, where the timestamp is the start time from the \
    beginning of the audio. Output only the transcript.
    """

    static let firmer = """
    IMPORTANT: your previous answer contained Devanagari or other non-Latin characters. Every word must be in \
    Latin letters only. Romanise Hindi words (e.g. "है" → "hai", "नहीं" → "nahi").
    """

    public static func text(names: NamesList, firmer: Bool = false) -> String {
        var t = base
        if !names.terms.isEmpty {
            t += "\nNames and terms that may occur; spell them exactly like this: " + names.terms.joined(separator: ", ")
        }
        if firmer { t += "\n" + Self.firmer }
        return t
    }
}

public struct GeminiSpeech: SpeechEngine {
    public let client: GeminiClient
    public let model: String
    public let thinkingLevel: String
    public var info: EngineInfo { EngineInfo(name: "Gemini", model: model, location: "Google cloud; audio sent to Google") }

    public init(client: GeminiClient, model: String, thinkingLevel: String) {
        self.client = client
        self.model = model
        self.thinkingLevel = thinkingLevel
    }

    public func transcribe(_ part: AudioPart, names: NamesList) async throws -> SpeechResult {
        let audio = try Data(contentsOf: part.file)
        var usage = Usage()
        var best: (parsed: TranscriptText.Parsed, nonLatin: Double, pastEnd: Double, paragraphs: Double)?
        // At most two tries: again if the answer is unparseable, has times past the end of the audio, is
        // not in Roman script, or puts speech in long paragraphs without times.
        for attempt in 0..<2 {
            var request = GeminiClient.Request(model: model, text: TranscriptionPrompt.text(names: names, firmer: attempt > 0 && (best?.nonLatin ?? 0) > 0.01),
                                               audio: audio, thinkingLevel: thinkingLevel)
            request.temperature = 0
            let response = try await client.generate(request)
            usage = usage + response.usage
            let parsed = TranscriptText.parseModelOutput(response.text, speaker: part.speaker, duration: part.duration)
            let nonLatin = TranscriptText.nonLatinFraction(parsed.segments.map(\.text).joined(separator: " "))
            let pastEnd = parsed.segments.isEmpty ? 0
                : Double(parsed.segments.filter { $0.start > part.duration + 5 }.count) / Double(parsed.segments.count)
            let paragraphs = TranscriptText.paragraphFraction(parsed.segments)
            let candidate = (parsed, nonLatin, pastEnd, paragraphs)
            if best == nil || score(candidate) < score(best!) { best = candidate }
            if parsed.unparsedFraction <= 0.2 && pastEnd <= 0.2 && nonLatin <= 0.01 && paragraphs <= 0.1 { break }
            client.log(String(format: "part %@ retry: %.0f%% unparsed lines, %.0f%% past the end, %.1f%% non-Latin letters, %.0f%% in paragraphs",
                              part.file.lastPathComponent, parsed.unparsedFraction * 100, pastEnd * 100, nonLatin * 100, paragraphs * 100))
        }
        // Still paragraphs after the retry: split them into sentences with estimated times.
        let (segments, split) = TranscriptText.splitParagraphs(best!.parsed.segments, end: part.duration)
        if split > 0 { client.log("part \(part.file.lastPathComponent): split \(split) paragraph(s) into sentences with estimated times") }
        return SpeechResult(segments: segments, usage: usage, nonLatin: best!.nonLatin)
    }

    private func score(_ c: (parsed: TranscriptText.Parsed, nonLatin: Double, pastEnd: Double, paragraphs: Double)) -> Double {
        c.parsed.unparsedFraction + c.pastEnd + c.nonLatin * 10 + c.paragraphs
    }
}

public struct GeminiSummary: SummaryEngine {
    public let client: GeminiClient
    public let model: String
    public let thinkingLevel: String
    public var info: EngineInfo { EngineInfo(name: "Gemini", model: model, location: "Google cloud") }

    public init(client: GeminiClient, model: String, thinkingLevel: String) {
        self.client = client
        self.model = model
        self.thinkingLevel = thinkingLevel
    }

    public func summarise(prompt: String) async throws -> (text: String, usage: Usage) {
        var request = GeminiClient.Request(model: model, text: prompt, thinkingLevel: thinkingLevel)
        request.temperature = 0
        request.maxOutputTokens = 16_384
        let response = try await client.generate(request)
        return (response.text, response.usage)
    }
}
