import Foundation
import Testing
@testable import EkoCore

struct TranscriptTextTests {
    @Test func parsesBothTimestampFormsAndJoinsContinuationLines() {
        let text = """
        ```
        [00:00:03] Hello, kaise ho?
        [01:05] Theek hoon yaar.
        and you?
        [1:02:07] Speaker 1: Bye.
        ```
        """
        let p = TranscriptText.parseModelOutput(text, speaker: .others)
        #expect(p.segments == [
            Segment(start: 3, speaker: .others, text: "Hello, kaise ho?"),
            Segment(start: 65, speaker: .others, text: "Theek hoon yaar. and you?"),
            Segment(start: 3727, speaker: .others, text: "Bye."),
        ])
        #expect(p.unparsedLines == 0)
    }

    @Test func countsLeadingLinesWithoutTimestampsAsUnparsed() {
        let p = TranscriptText.parseModelOutput("Here is the transcript:\nno stamps here\n[00:01] ok", speaker: .you)
        #expect(p.unparsedLines == 2)
        #expect(p.totalLines == 3)
        #expect(p.segments.count == 1)
    }

    @Test func cleanDropsLinesPastTheEndSortsAndCollapsesRepeats() {
        let segs = [5, 1, 2, 3, 4, 6, 7, 200].enumerated().map { i, t in
            Segment(start: Double(t), speaker: .you, text: i == 0 ? "first" : (t == 200 ? "ghost" : "ok ok"))
        }
        let c = TranscriptText.clean(segs, duration: 100)
        #expect(c.outOfRange == 1)
        #expect(c.segments.map(\.start) == [1, 2, 3, 5, 6, 7])   // the 4th identical line in a row (at 4 s) is dropped
        #expect(c.repeatsCollapsed == 1)
    }

    @Test func nonLatinFractionFlagsDevanagariAndCJK() {
        #expect(TranscriptText.nonLatinFraction("Haan theek hai, kal milte hain. Café déjà vu.") == 0)
        #expect(TranscriptText.nonLatinFraction("नहीं yaar") > 0.3)
        #expect(TranscriptText.nonLatinFraction("ok 嗯") > 0.3)
    }

    @Test func mergeInterleavesByTimeWithYouFirstOnTies() {
        let you = [Segment(start: 0, speaker: .you, text: "a"), Segment(start: 10, speaker: .you, text: "c")]
        let others = [Segment(start: 10, speaker: .others, text: "d"), Segment(start: 5, speaker: .others, text: "b")]
        #expect(TranscriptText.merge([you, others]).map(\.text) == ["a", "b", "c", "d"])
    }

    @Test func bleedRemovesEchoedYouLinesOnly() {
        let segs = [
            Segment(start: 10, speaker: .others, text: "Shall we start with the pricing update today"),
            Segment(start: 11, speaker: .you, text: "shall we start with the pricing update"),   // echo
            Segment(start: 30, speaker: .you, text: "shall we start with the pricing update"),   // too far apart
            Segment(start: 12, speaker: .you, text: "Yes please"),                              // short
        ]
        let (kept, removed) = TranscriptText.removeBleed(segs)
        #expect(removed == 1)
        #expect(kept.count == 3)
    }

    @Test func fileRoundTripKeepsSpeakersAndTimes() {
        let segs = [
            Segment(start: 3, speaker: .you, text: "Hello."),
            Segment(start: 3725, speaker: .others, text: "Haan, audible hai: bolo."),
        ]
        let header = TranscriptText.Header(recording: "x.m4a", date: "2026-11-13 11:23", duration: 3800, apps: ["Chrome"],
                                           engine: "Gemini m", labelled: true, checks: ["script OK"])
        let text = TranscriptText.render(header: header, segments: segs)
        #expect(text.contains("[01:02:05] Others: Haan, audible hai: bolo."))
        #expect(text.contains("Duration: 01:03:20 · Apps: Chrome"))
        #expect(TranscriptText.parseFile(text) == segs)
    }

    @Test func unlabelledLinesHaveNoSpeaker() {
        let header = TranscriptText.Header(recording: "x.m4a", date: "d", duration: 10, apps: [], engine: "e", labelled: false, checks: [])
        let text = TranscriptText.render(header: header, segments: [Segment(start: 1, speaker: .unlabelled, text: "hi")])
        #expect(text.hasSuffix("[00:00:01] hi\n"))
        #expect(TranscriptText.parseFile(text) == [Segment(start: 1, speaker: .unlabelled, text: "hi")])
    }
}

struct SummaryTests {
    @Test func rendersPlaceholdersAndLeavesTranscriptTextAlone() {
        let names = NamesList(text: "# comment\nme: Nirdesh\nDevsoor\n\nToast\nDevsoor")
        #expect(names.me == "Nirdesh")
        #expect(names.terms == ["Nirdesh", "Devsoor", "Toast"])
        let v = SummaryPrompt.Values(title: "Call", date: "2026-11-13 11:23", duration: 2331, labelled: true, names: names,
                                     transcript: "[00:00:01] You: say {{names}} literally")
        let out = SummaryPrompt.render(template: SummaryPrompt.defaultTemplate, v)
        #expect(out.contains("Duration: 00:38:51"))
        #expect(out.contains("You = Nirdesh, who recorded the call."))
        #expect(out.contains("list: Nirdesh, Devsoor, Toast"))
        #expect(out.hasSuffix("say {{names}} literally"))
    }

    @Test func timestampCheckAllowsTenSeconds() {
        let segs = [Segment(start: 100, speaker: .you, text: "a"), Segment(start: 2000, speaker: .others, text: "b")]
        let summary = "- one [00:01:40]\n- two [00:01:49]\n- three [00:33:28]\n- four [00:20:00]"
        let c = SummaryPrompt.checkTimestamps(summary, against: segs)
        #expect(c.cited == 4)
        #expect(c.matched == 3)
        #expect(c.line == "3 of 4 cited timestamps match a transcript line.")
    }

    @Test func customTemplateWithoutTranscriptPlaceholderGetsOne() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("p.txt")
        try "Summarise briefly.".write(to: file, atomically: true, encoding: .utf8)
        let t = SummaryPrompt.loadTemplate(from: file)
        #expect(t.source == "p.txt")
        #expect(t.template.contains("{{transcript}}"))
        #expect(SummaryPrompt.loadTemplate(from: dir.appendingPathComponent("missing")).source == "built-in default")
    }
}

struct TimestampFormTests {
    @Test func minutesSecondsHundredthsAreRecognisedWhenHoursCannotFit() {
        let text = "[00:05:12] early\n[05:23:40] middle\n[38:41:07] late"
        let p = TranscriptText.parseModelOutput(text, speaker: .others, duration: 2332)
        #expect(p.segments.map(\.start) == [5.12, 323.4, 2321.07])
    }

    @Test func realHoursAreKeptWhenTheyFit() {
        let text = "[00:05:12] a\n[01:02:03] b"
        let p = TranscriptText.parseModelOutput(text, speaker: .you, duration: 4000)
        #expect(p.segments.map(\.start) == [312, 3723])
        #expect(TranscriptText.parseModelOutput(text, speaker: .you).segments.map(\.start) == [312, 3723])
    }
}

@Test func inlineStampsInOneParagraphBecomeSeparateLines() {
    let reply = "[00:00:00] Hey Nirdesh. [00:04] Woh batao yaar. [01:39] Toh yeh build kar raha hai? [37:10] Thik hai."
    let parsed = TranscriptText.parseModelOutput(reply, speaker: .others, duration: 2300)
    #expect(parsed.segments.map(\.start) == [0, 4, 99, 2230])
    #expect(parsed.segments.map(\.text) == ["Hey Nirdesh.", "Woh batao yaar.", "Toh yeh build kar raha hai?", "Thik hai."])
}

@Test func longYouLineIsNotRemovedAsEchoOfAShortOne() {
    let segments = [
        Segment(start: 0, speaker: .others, text: "hey are you there can you hear me"),
        Segment(start: 1, speaker: .you, text: "hey are you there can you hear me yes I can hear you fine let us start with the report then talk about pricing"),
        Segment(start: 10, speaker: .you, text: "so what about the toast connector"),
        Segment(start: 10.5, speaker: .others, text: "so what about the toast connector"),
    ]
    let (kept, removed) = TranscriptText.removeBleed(segments)
    #expect(removed == 1)
    #expect(kept.count == 3)
    #expect(kept.contains { $0.speaker == .you && $0.start == 1 })
}

@Test func paragraphWithoutTimesIsSplitIntoSentencesWithEstimatedTimes() {
    let sentence = "Toh yeh jo additional build kar raha hai, iske liye charge karega kya yeh? "
    let paragraph = String(repeating: sentence, count: 20)   // ~1500 characters, no times
    let segments = [Segment(start: 100, speaker: .others, text: paragraph), Segment(start: 400, speaker: .others, text: "Thik hai.")]
    #expect(TranscriptText.paragraphFraction(segments) > 0.9)
    let (out, split) = TranscriptText.splitParagraphs(segments, end: 500)
    #expect(split == 1)
    #expect(out.count > 5)
    #expect(out.first?.start == 100)
    #expect(out.dropLast().allSatisfy { $0.text.count < 300 && $0.start >= 100 && $0.start < 400 })
    #expect(out.map(\.start) == out.map(\.start).sorted())
    #expect(out.last?.text == "Thik hai.")
}

@Test func bareInlineTimesInOneParagraphBecomeSeparateLines() {
    let reply = "[00:00:13] Haan, 00:00:20 class ka number hai 00:00:22 mere paas. 00:00:25 Shiva se baat nahi hua? 00:02:30 Mm, what else?"
    let parsed = TranscriptText.parseModelOutput(reply, speaker: .others, duration: 1000)
    #expect(parsed.segments.map(\.start) == [13, 20, 22, 25, 150])
    #expect(parsed.segments[1].text == "class ka number hai")
}

@Test func aTimeSomeoneSaysStaysText() {
    let reply = "[00:01:00] Let's meet at 10:30 tomorrow.\n[00:01:05] Okay."
    let parsed = TranscriptText.parseModelOutput(reply, speaker: .others, duration: 1000)
    #expect(parsed.segments.count == 2)
    #expect(parsed.segments[0].text == "Let's meet at 10:30 tomorrow.")
}
