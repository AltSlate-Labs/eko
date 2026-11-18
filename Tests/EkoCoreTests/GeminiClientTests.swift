import Foundation
import Testing
@testable import EkoCore

/// Answers requests from a queue of canned responses and records what was sent. No network.
final class StubProtocol: URLProtocol {
    struct Reply { var status: Int; var body: String; var headers: [String: String] = [:] }
    static var replies: [Reply] = []
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []

    static func reset(_ replies: [Reply]) {
        self.replies = replies
        requests = []
        bodies = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        Self.bodies.append(request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data())
        let reply = Self.replies.isEmpty ? Reply(status: 500, body: "{}") : Self.replies.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

func ok(_ text: String, finish: String = "STOP") -> StubProtocol.Reply {
    let body: [String: Any] = [
        "candidates": [["content": ["parts": [["text": text]], "role": "model"], "finishReason": finish]],
        "usageMetadata": ["promptTokenCount": 100, "candidatesTokenCount": 20, "thoughtsTokenCount": 5],
    ]
    return .init(status: 200, body: String(data: try! JSONSerialization.data(withJSONObject: body), encoding: .utf8)!)
}

func googleError(_ code: Int, _ status: String, _ message: String, details: String = "[]") -> StubProtocol.Reply {
    .init(status: code, body: #"{"error":{"code":\#(code),"status":"\#(status)","message":"\#(message)","details":\#(details)}}"#)
}

let secretKey = "AQ.TEST-SECRET-KEY-1234"

func makeClient(sleeps: Box<[TimeInterval]> = Box([])) -> GeminiClient {
    let client = GeminiClient(key: secretKey, session: GeminiClient.makeSession(protocolClasses: [StubProtocol.self]))
    client.sleep = { sleeps.value.append($0) }
    client.log = { _ in }
    return client
}

final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

@Suite(.serialized) struct GeminiClientTests {
    @Test func sendsKeyInHeaderAudioInlineAndThinkingConfig() async throws {
        StubProtocol.reset([ok("[00:01] hi")])
        var r = GeminiClient.Request(model: "gemini-3.6-flash", text: "Transcribe", audio: Data([1, 2, 3]), thinkingLevel: "low")
        r.temperature = 0
        let response = try await makeClient().generate(r)
        #expect(response.text == "[00:01] hi")
        #expect(response.usage == Usage(inputTokens: 100, outputTokens: 20, thoughtTokens: 5))
        let req = try #require(StubProtocol.requests.first)
        #expect(req.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.6-flash:generateContent")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == secretKey)
        #expect(!(req.url?.absoluteString.contains(secretKey) ?? true))
        let json = try #require(JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: Any])
        let parts = ((json["contents"] as? [[String: Any]])?.first?["parts"] as? [[String: Any]]) ?? []
        #expect((parts.first?["inline_data"] as? [String: Any])?["data"] as? String == "AQID")
        #expect((parts.first?["inline_data"] as? [String: Any])?["mime_type"] as? String == "audio/mp4")
        let config = json["generationConfig"] as? [String: Any]
        #expect((config?["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "low")
        #expect(config?["temperature"] as? Double == 0)
    }

    @Test func retriesServerErrorsThenSucceeds() async throws {
        StubProtocol.reset([.init(status: 503, body: "{}"), ok("done")])
        let sleeps = Box<[TimeInterval]>([])
        let response = try await makeClient(sleeps: sleeps).generate(.init(model: "m", text: "t"))
        #expect(response.text == "done")
        #expect(sleeps.value == [20])
    }

    /// Failed tries count against the daily quota: one retry, then the queue waits.
    @Test func gives_up_on_persistent_server_errors() async {
        StubProtocol.reset(Array(repeating: .init(status: 503, body: "{}"), count: 5))
        await #expect(throws: GeminiError.server(503)) { try await makeClient().generate(.init(model: "m", text: "t")) }
        #expect(StubProtocol.requests.count == 2)
    }

    @Test func perMinuteRateLimitHonoursRetryDelay() async throws {
        let details = #"[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"7s"}]"#
        StubProtocol.reset([googleError(429, "RESOURCE_EXHAUSTED", "Quota exceeded", details: details), ok("fine")])
        let sleeps = Box<[TimeInterval]>([])
        _ = try await makeClient(sleeps: sleeps).generate(.init(model: "m", text: "t"))
        #expect(sleeps.value == [7])
    }

    /// Shape of the real answer captured on 2026-11-15 (free tier: 20 requests a day per model).
    static let dailyDetails = #"[{"@type":"type.googleapis.com/google.rpc.Help","links":[{"description":"Learn more about Gemini API quotas","url":"https://aistudio.google.com/docs/rate-limits"}]},{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"description":"Generate content requests per day limit exceeded on Free Tier.","quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier","quotaDimensions":{"model":"gemini-3.6-flash","location":"global"},"quotaValue":"20"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"83202s"}]"#

    @Test func dailyQuotaUsesGooglesRetryDelayForTheReset() async throws {
        StubProtocol.reset([googleError(429, "RESOURCE_EXHAUSTED", "You exceeded your current quota", details: Self.dailyDetails), ok("never")])
        let client = makeClient()
        let now = Date(timeIntervalSince1970: 1_000_000)
        client.now = { now }
        do {
            _ = try await client.generate(.init(model: "m", text: "t"))
            Issue.record("expected quotaExhausted")
        } catch let GeminiError.quotaExhausted(resetAt) {
            #expect(resetAt == now.addingTimeInterval(83_202))
            #expect(StubProtocol.requests.count == 1)
        }
    }

    @Test func dailyQuotaWithoutRetryDelayResetsAtMidnightPacific() async throws {
        let details = #"[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]}]"#
        StubProtocol.reset([googleError(429, "RESOURCE_EXHAUSTED", "You exceeded your current quota", details: details), ok("never")])
        let client = makeClient()
        let now = ISO8601DateFormatter().date(from: "2026-11-15T10:00:00Z")!   // 02:00 Pacific
        client.now = { now }
        do {
            _ = try await client.generate(.init(model: "m", text: "t"))
            Issue.record("expected quotaExhausted")
        } catch let GeminiError.quotaExhausted(resetAt) {
            #expect(ISO8601DateFormatter().string(from: resetAt) == "2026-11-16T08:00:00Z")   // midnight Pacific (PST)
            #expect(StubProtocol.requests.count == 1)
        }
    }

    @Test func mapsKeyAndModelErrors() async {
        StubProtocol.reset([googleError(400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.",
                                        details: #"[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID"}]"#)])
        await #expect(throws: GeminiError.keyRejected("API key not valid. Please pass a valid API key.")) {
            try await makeClient().generate(.init(model: "m", text: "t"))
        }
        StubProtocol.reset([googleError(404, "NOT_FOUND", "models/old is not found")])
        await #expect(throws: GeminiError.modelNotFound("old")) { try await makeClient().generate(.init(model: "old", text: "t")) }
        await #expect(throws: GeminiError.modelNotFound("../files")) { try await makeClient().generate(.init(model: "../files", text: "t")) }
    }

    @Test func maxTokensAndBlockedAnswersAreErrors() async {
        StubProtocol.reset([ok("partial", finish: "MAX_TOKENS")])
        await #expect(throws: GeminiError.maxTokens) { try await makeClient().generate(.init(model: "m", text: "t")) }
        StubProtocol.reset([ok("", finish: "SAFETY")])
        await #expect(throws: GeminiError.blocked("SAFETY")) { try await makeClient().generate(.init(model: "m", text: "t")) }
    }

    @Test func refusesRedirects() async {
        StubProtocol.reset([.init(status: 302, body: "", headers: ["Location": "https://evil.example/collect"])])
        await #expect(throws: GeminiError.self) { try await makeClient().generate(.init(model: "m", text: "t")) }
        #expect(StubProtocol.requests.allSatisfy { $0.url?.host == GeminiClient.host })
    }

    @Test func errorTextNeverContainsTheKey() {
        let errors: [GeminiError] = [.noKey, .keyRejected("bad"), .modelNotFound("m"), .quotaExhausted(resetAt: Date()), .rateLimited,
                                     .server(503), .network("x"), .badRequest("y"), .blocked("SAFETY"), .maxTokens, .invalidResponse("z")]
        for e in errors { #expect(!(e.errorDescription ?? "").contains(secretKey)) }
        #expect(KeyStore.masked(secretKey) == "…1234")
        #expect(KeyStore.clean("  \"\(secretKey)\"\n") == secretKey)
    }

    @Test func chatSendsSystemInstructionAndEarlierTurns() async throws {
        StubProtocol.reset([ok("v1 ships on the 17th [00:12:03].")])
        let segments = [Segment(start: 723, speaker: .others, text: "Ship on the 17th.")]
        let answer = try await CallChat.ask("When do we ship?", history: [ChatMessage(role: .user, text: "Hi"), ChatMessage(role: .model, text: "Hello")],
                                            system: "RULES <transcript>…</transcript>", segments: segments,
                                            client: makeClient(), model: "gemini-3.5-flash-lite")
        #expect(answer.role == .model && answer.cited == 1 && answer.matched == 1)
        let json = try #require(JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: Any])
        let system = ((json["systemInstruction"] as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String
        #expect(system == "RULES <transcript>…</transcript>")
        let contents = try #require(json["contents"] as? [[String: Any]])
        #expect(contents.map { $0["role"] as? String } == ["user", "model", "user"])
        #expect(((contents[2]["parts"] as? [[String: Any]])?.first?["text"] as? String) == "When do we ship?")
        #expect(StubProtocol.requests.first?.url?.path == "/v1beta/models/gemini-3.5-flash-lite:generateContent")
    }

    @Test func plainRequestsHaveNoSystemInstruction() async throws {
        StubProtocol.reset([ok("x")])
        _ = try await makeClient().generate(.init(model: "m", text: "t"))
        let json = try #require(JSONSerialization.jsonObject(with: StubProtocol.bodies[0]) as? [String: Any])
        #expect(json["systemInstruction"] == nil)
        #expect((json["contents"] as? [[String: Any]])?.count == 1)
    }

    @Test func checkKeyUsesModelMetadata() async throws {
        StubProtocol.reset([.init(status: 200, body: #"{"name":"models/gemini-3.6-flash"}"#)])
        try await makeClient().checkKey(model: "gemini-3.6-flash")
        #expect(StubProtocol.requests.first?.httpMethod == "GET")
        #expect(StubProtocol.requests.first?.url?.path == "/v1beta/models/gemini-3.6-flash")
    }
}
