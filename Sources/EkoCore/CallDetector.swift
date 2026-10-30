import Foundation

/// Detects calls by watching which known call apps hold the microphone open.
///
/// A call is considered started when a known app (Zoom, Teams, a browser for Meet, …) has
/// been using the microphone on two consecutive polls, and ended after it has released it
/// on three consecutive polls. Our own process is ignored (we use the mic while recording).
public final class CallDetector {
    public var onCallStarted: ((String) -> Void)?
    public var onCallEnded: ((String) -> Void)?
    public private(set) var activeApp: String?

    private let queue = DispatchQueue(label: "eko.detector")
    private var timer: DispatchSourceTimer?
    private var candidate: String?
    private var candidateCount = 0
    private var absentCount = 0
    private let startPolls = 2
    private let endPolls = 3

    public init() {}

    public func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Name of the known call app currently using the microphone, if any.
    public static func currentCallApp() -> String? {
        let me = pid_t(ProcessInfo.processInfo.processIdentifier)
        let apps = AudioProcess.usingMicrophone(excluding: [me]).filter(\.isKnownCallApp)
        var seen: [String: Int] = [:]
        for app in apps { seen[app.displayName, default: 0] += 1 }
        return KnownApps.preferredName(from: seen)
    }

    private func poll() {
        let name = Self.currentCallApp()
        if let active = activeApp {
            if name == nil {
                absentCount += 1
                if absentCount >= endPolls {
                    activeApp = nil
                    absentCount = 0
                    onCallEnded?(active)
                }
            } else {
                absentCount = 0
            }
            return
        }
        guard let name else {
            candidate = nil
            candidateCount = 0
            return
        }
        if name == candidate { candidateCount += 1 } else { candidate = name; candidateCount = 1 }
        if candidateCount >= startPolls {
            activeApp = name
            candidate = nil
            candidateCount = 0
            absentCount = 0
            onCallStarted?(name)
        }
    }
}
