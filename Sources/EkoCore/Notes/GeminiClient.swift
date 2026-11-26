import Foundation

public struct Usage: Codable, Equatable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var thoughtTokens = 0
    public init(inputTokens: Int = 0, outputTokens: Int = 0, thoughtTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
    }
    public static func + (a: Usage, b: Usage) -> Usage {
        Usage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
              thoughtTokens: a.thoughtTokens + b.thoughtTokens)
    }
    public var summary: String { "\(inputTokens) in, \(outputTokens) out, \(thoughtTokens) thinking tokens" }
}

public enum GeminiError: Error, LocalizedError, Equatable {
    case noKey
    case keyRejected(String)
    case modelNotFound(String)
    /// The key's daily quota (free tier) is used up; requests work again after `resetAt`.
    case quotaExhausted(resetAt: Date)
    /// Per-minute limits still hit after the in-call retries.
    case rateLimited
    case server(Int)
    case network(String)
    case badRequest(String)
    case blocked(String)
    case maxTokens
    case invalidResponse(String)

    /// Worth trying the same job again later without the user changing anything.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server, .network, .quotaExhausted: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noKey: return "No Gemini API key is set."
        case .keyRejected: return "Google did not accept the Gemini API key. Copy it again from AI Studio and set it in Eko."
        case let .modelNotFound(model):
            return "Gemini model \"\(model)\" is not available. Set another with: defaults write com.altslate.eko notes.transcribeModel <model id>"
        case let .quotaExhausted(resetAt):
            let f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            return "Gemini's free daily limit is used up. Transcripts will continue after it resets (about \(f.string(from: resetAt)))."
        case .rateLimited: return "Gemini's usage limit was reached. Eko will try again shortly."
        case let .server(code): return "Gemini is unavailable right now (HTTP \(code)). Eko will try again."
        case let .network(detail): return "Couldn't reach Gemini: \(detail)"
        case let .badRequest(detail): return "Gemini rejected the request: \(detail)"
        case let .blocked(reason): return "Gemini declined to answer (\(reason))."
        case .maxTokens: return "Gemini's answer was cut off (too long)."
        case let .invalidResponse(detail): return "Unexpected answer from Gemini: \(detail)"
        }
    }
}

/// Minimal client for one Gemini call (`models/<id>:generateContent`) over URLSession: audio inline as base64,
/// nothing stored in Google's Files service. The key travels only in the `x-goog-api-key` header.
public final class GeminiClient {
    public static let host = "generativelanguage.googleapis.com"

    public struct Request {
        public var model: String
        public var text: String
        public var audio: Data?
        public var audioMimeType = "audio/mp4"
        public var thinkingLevel: String?
        public var temperature: Double? = 0
        public var maxOutputTokens = 65_536
        /// Standing instructions (chat: the rules and the transcript).
        public var systemInstruction: String?
        /// Earlier turns of a conversation, oldest first; `text` is the new user turn.
        public var history: [Turn] = []
        public init(model: String, text: String, audio: Data? = nil, thinkingLevel: String? = nil) {
            self.model = model
            self.text = text
            self.audio = audio
            self.thinkingLevel = thinkingLevel
        }
    }

    public struct Turn: Equatable {
        public enum Role: String { case user, model }
        public var role: Role
        public var text: String
        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    public struct Response: Equatable {
        public var text: String
        public var finishReason: String?
        public var usage: Usage
    }

    private let key: String
    private let session: URLSession
    var sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    var now: () -> Date = Date.init
    var log: (String) -> Void = { RecordingSession.dlog("notes: \($0)") }
    /// Failed requests (429, 503) count against the free daily quota (~20 a day), so retry little here; the queue
    /// waits 15–30 minutes before the next try (NotesQueue.retryDelays), or pauses
    /// everything 30 min to 4 h when Gemini stays overloaded (NotesQueue.overloadDelays).
    static let rateDelays: [TimeInterval] = [30, 60]
    static let serverDelays: [TimeInterval] = [120]
    /// A request that never reached Google costs no quota.
    static let networkDelays: [TimeInterval] = [5, 15, 45, 120]

    public init(key: String, session: URLSession? = nil) {
        self.key = key
        self.session = session ?? GeminiClient.makeSession()
    }

    public static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        config.httpAdditionalHeaders = ["User-Agent": "Eko"]
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    // MARK: Calls

    /// Checks the key and model without using tokens (model metadata request).
    public func checkKey(model: String) async throws {
        var request = URLRequest(url: try modelURL(model, suffix: ""))
        request.httpMethod = "GET"
        let (data, status) = try await send(request)
        if status == 200 { return }
        throw mapError(status: status, data: data, model: model) ?? GeminiError.badRequest("HTTP \(status)")
    }

    public func generate(_ r: Request) async throws -> Response {
        var parts: [[String: Any]] = []
        if let audio = r.audio {
            parts.append(["inline_data": ["mime_type": r.audioMimeType, "data": audio.base64EncodedString()]])
        }
        parts.append(["text": r.text])
        var config: [String: Any] = ["maxOutputTokens": r.maxOutputTokens]
        if let t = r.temperature { config["temperature"] = t }
        if let level = r.thinkingLevel { config["thinkingConfig"] = ["thinkingLevel": level] }
        let earlier: [[String: Any]] = r.history.map { ["role": $0.role.rawValue, "parts": [["text": $0.text]]] }
        var payload: [String: Any] = ["contents": earlier + [["role": "user", "parts": parts]], "generationConfig": config]
        if let system = r.systemInstruction { payload["systemInstruction"] = ["parts": [["text": system]]] }

        var request = URLRequest(url: try modelURL(r.model, suffix: ":generateContent"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var rateTries = 0, serverTries = 0, networkTries = 0
        while true {
            let started = now()
            let data: Data, status: Int
            do {
                (data, status) = try await send(request)
            } catch let error as GeminiError {
                throw error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                guard networkTries < Self.networkDelays.count else { throw GeminiError.network(error.localizedDescription) }
                log("network error (\(error.localizedDescription)); retry in \(Int(Self.networkDelays[networkTries])) s")
                try await sleep(Self.networkDelays[networkTries])
                networkTries += 1
                continue
            }
            log(String(format: "%@ HTTP %d in %.1f s (%d KB sent)", r.model, status, now().timeIntervalSince(started), (request.httpBody?.count ?? 0) / 1024))
            switch status {
            case 200:
                return try parse(data)
            case 429:
                let info = Self.quotaInfo(data)
                if info.daily || (info.retryDelay ?? 0) > 600 {
                    // Google's retryDelay points at the reset (midnight Pacific); fall back to computing it.
                    let reset = info.retryDelay.map { now().addingTimeInterval($0) } ?? Self.nextQuotaReset(after: now())
                    throw GeminiError.quotaExhausted(resetAt: reset)
                }
                guard rateTries < Self.rateDelays.count else { throw GeminiError.rateLimited }
                let delay = min(info.retryDelay ?? Self.rateDelays[rateTries], 300)
                log("rate limited; retry in \(Int(delay)) s")
                try await sleep(delay)
                rateTries += 1
            case 500, 502, 503, 504:
                guard serverTries < Self.serverDelays.count else { throw GeminiError.server(status) }
                log("server error \(status); retry in \(Int(Self.serverDelays[serverTries])) s")
                try await sleep(Self.serverDelays[serverTries])
                serverTries += 1
            default:
                throw mapError(status: status, data: data, model: r.model) ?? GeminiError.badRequest("HTTP \(status)")
            }
        }
    }

    // MARK: Plumbing

    private func modelURL(_ model: String, suffix: String) throws -> URL {
        // Model ids are plain tokens; anything else would change the request path.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        guard !model.isEmpty, model.unicodeScalars.allSatisfy(allowed.contains),
              let url = URL(string: "https://\(Self.host)/v1beta/models/\(model)\(suffix)") else {
            throw GeminiError.modelNotFound(model)
        }
        return url
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        var request = request
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        guard request.url?.scheme == "https", request.url?.host == Self.host else {
            throw GeminiError.invalidResponse("refusing to send to \(request.url?.host ?? "?")")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GeminiError.invalidResponse("no HTTP response") }
        if (300..<400).contains(http.statusCode) { throw GeminiError.invalidResponse("unexpected redirect") }
        return (data, http.statusCode)
    }

    private func parse(_ data: Data) throws -> Response {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GeminiError.invalidResponse("not JSON")
        }
        let meta = json["usageMetadata"] as? [String: Any] ?? [:]
        let usage = Usage(inputTokens: meta["promptTokenCount"] as? Int ?? 0,
                          outputTokens: meta["candidatesTokenCount"] as? Int ?? 0,
                          thoughtTokens: meta["thoughtsTokenCount"] as? Int ?? 0)
        guard let candidate = (json["candidates"] as? [[String: Any]])?.first else {
            let reason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw reason.map { GeminiError.blocked($0) } ?? GeminiError.invalidResponse("no candidates")
        }
        let finish = candidate["finishReason"] as? String
        let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { part -> String? in
            if part["thought"] as? Bool == true { return nil }
            return part["text"] as? String ?? (part["audioTranscription"] as? [String: Any])?["text"] as? String
        }.joined()
        switch finish {
        case nil, "STOP": break
        case "MAX_TOKENS": throw GeminiError.maxTokens
        default: throw GeminiError.blocked(finish ?? "unknown")
        }
        return Response(text: text, finishReason: finish, usage: usage)
    }

    private func mapError(status: Int, data: Data, model: String) -> GeminiError? {
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        let message = error?["message"] as? String ?? ""
        let details = error?["details"] as? [[String: Any]] ?? []
        let reasons = details.compactMap { $0["reason"] as? String }
        log("HTTP \(status) \(error?["status"] as? String ?? "") \(reasons.joined(separator: ",")): \(message.prefix(200))")
        if reasons.contains(where: { $0.contains("API_KEY") }) || message.localizedCaseInsensitiveContains("API key") {
            return .keyRejected(message)
        }
        switch status {
        case 401, 403: return .keyRejected(message)
        case 404: return .modelNotFound(model)
        case 400...499: return .badRequest(message.isEmpty ? "HTTP \(status)" : String(message.prefix(300)))
        default: return nil
        }
    }

    /// Reads Google's `google.rpc` error details of a 429: a daily quota (QuotaFailure violation whose quota id
    /// or metric names a per-day limit) and the suggested retry delay (RetryInfo).
    static func quotaInfo(_ data: Data) -> (daily: Bool, retryDelay: TimeInterval?) {
        let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
        var daily = false
        var delay: TimeInterval?
        for detail in error?["details"] as? [[String: Any]] ?? [] {
            for v in detail["violations"] as? [[String: Any]] ?? [] {
                let id = ((v["quotaId"] as? String ?? "") + " " + (v["quotaMetric"] as? String ?? "")).lowercased()
                if id.contains("perday") || id.contains("per_day") { daily = true }
            }
            if let text = detail["retryDelay"] as? String, text.hasSuffix("s"), let s = Double(text.dropLast()) {
                delay = s
            }
        }
        return (daily, delay)
    }

    /// Gemini's daily quotas reset at midnight Pacific time.
    static func nextQuotaReset(after date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let startOfDay = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: startOfDay) ?? date.addingTimeInterval(86_400)
    }
}

/// The API never redirects; following one could send the key and audio elsewhere.
private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
