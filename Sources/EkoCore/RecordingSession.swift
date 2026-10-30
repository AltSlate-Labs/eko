import AVFoundation
import CoreAudio
import Foundation
import os

public struct RecordingOptions {
    public var outputDirectory: URL
    public var format: OutputFormat
    public var bitRate: Int
    public var micGain: Float
    public var systemGain: Float
    /// Extra PIDs to exclude from the system audio tap (our own process is always excluded).
    public var excludedPIDs: [pid_t]

    public init(
        outputDirectory: URL = RecordingOptions.defaultDirectory,
        format: OutputFormat = .aac,
        bitRate: Int = 160_000,
        micGain: Float = 1.0,
        systemGain: Float = 1.0,
        excludedPIDs: [pid_t] = []
    ) {
        self.outputDirectory = outputDirectory
        self.format = format
        self.bitRate = bitRate
        self.micGain = micGain
        self.systemGain = systemGain
        self.excludedPIDs = excludedPIDs
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("CallRecordings", isDirectory: true)
    }
}

public enum RecordingEvent {
    case started(url: URL, captureSummary: String)
    /// First microphone audio received (normally within ~100 ms of `started`).
    case capturing
    case warning(String)
    case info(String)
    case devicesChanged(String)
    case stopped(url: URL, duration: TimeInterval)
    case failed(Error)
}

public struct RecordingLevels {
    public var mic: Float = 0
    public var system: Float = 0
    public var framesCaptured: Int = 0
    public var systemFrames: Int = 0
    public init() {}
}

/// Owns one recording from start to stop: mic capture, system-audio capture, the
/// time-aligned mixer, the file writer, device-change handling and final naming.
public final class RecordingSession {
    public enum State: Equatable { case idle, starting, recording, stopping }

    /// Diagnostics go to ~/Library/Logs/Eko.log and the unified log (subsystem com.altslate.eko).
    /// Set EKO_DEBUG=1 to also print them on stderr.
    static let debug = ProcessInfo.processInfo.environment["EKO_DEBUG"] != nil
    static let logger = Logger(subsystem: "com.altslate.eko", category: "session")
    static let logFileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Eko.log")
    private static let logQueue = DispatchQueue(label: "eko.log")
    private static let logTime: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f }()

    public static func dlog(_ message: @autoclosure () -> String) {
        let text = message()
        logger.notice("\(text, privacy: .public)")
        if debug { FileHandle.standardError.write("[debug] \(text)\n".data(using: .utf8)!) }
        let line = "\(logTime.string(from: Date())) [\(ProcessInfo.processInfo.processName)] \(text)\n"
        logQueue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logFileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: logFileURL)
            }
        }
    }

    public let options: RecordingOptions
    public var onEvent: ((RecordingEvent) -> Void)?
    public private(set) var state: State = .idle
    public private(set) var startedAt: Date?
    public private(set) var currentURL: URL?

    private let queue = DispatchQueue(label: "eko.session")
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var mixBus: MixBus?
    private var writer: AudioFileWriter?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var rebuildPending = false
    private var sampler: DispatchSourceTimer?
    private var appsSeen: [String: Int] = [:]
    private var permissionWarned = false
    private var capturingAnnounced = false
    private var captureSummary = ""

    public init(options: RecordingOptions = RecordingOptions()) {
        self.options = options
    }

    public var currentLevels: RecordingLevels {
        var l = RecordingLevels()
        guard let bus = mixBus else { return l }
        l.mic = bus.levels.mic
        l.system = bus.levels.system
        l.framesCaptured = Int(bus.framesMixed)
        l.systemFrames = Int(bus.systemFramesReceived)
        return l
    }

    public var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? 0 }

    // MARK: Start

    public func start() {
        queue.async { [self] in
            guard state == .idle else { return }
            state = .starting
            requestMicrophoneAccess { [self] granted in
                queue.async { [self] in
                    if !granted { emit(.warning("Microphone access not granted: only system audio will be recorded.")) }
                    do {
                        try beginRecording()
                    } catch {
                        state = .idle
                        teardownCaptures()
                        writer = nil
                        mixBus = nil
                        emit(.failed(error))
                    }
                }
            }
        }
    }

    private func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        Self.dlog("microphone authorization status: \(status.rawValue) (0 undetermined, 1 restricted, 2 denied, 3 authorized)")
        switch status {
        case .authorized: completion(true)
        case .notDetermined:
            emit(.info("Waiting for Microphone permission…"))
            let asked = Date()
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Self.dlog(String(format: "microphone prompt answered after %.1fs: granted=%d", Date().timeIntervalSince(asked), granted ? 1 : 0))
                completion(granted)
            }
        default: completion(false)
        }
    }

    private func beginRecording() throws {
        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let start = Date()
        startedAt = start
        appsSeen = [:]
        permissionWarned = false
        capturingAnnounced = false

        let url = RecordingNamer.url(in: options.outputDirectory, date: start, app: "Recording", ext: options.format.fileExtension)
        let writer = try AudioFileWriter(url: url, format: options.format, bitRate: options.bitRate)
        self.writer = writer
        currentURL = url

        let bus = MixBus(sampleRate: writer.targetFormat.sampleRate)
        bus.micGain = options.micGain
        bus.systemGain = options.systemGain
        bus.onOutput = { [weak writer] buffer in writer?.enqueue(buffer) }
        bus.onNotice = { message in Self.dlog("mix: \(message)") }
        mixBus = bus

        try buildMic()
        buildSystem()   // failure here is reported but does not abort: mic-only recording is still useful
        installDeviceListener()
        startSampler()
        state = .recording
        emit(.started(url: url, captureSummary: captureSummary))
        scheduleSilenceCheck()
    }

    private func buildMic() throws {
        let device = try AudioDevice.defaultInput()
        guard device.id != 0 else { throw CaptureError.noInputDevice }
        let mic = try MicCapture(device: device)
        guard let bus = mixBus else { return }
        try mic.start { [weak self, weak bus] buffer, host in
            guard let self, let bus else { return }
            bus.pushMic(buffer, hostTime: host)
            if !self.capturingAnnounced {
                self.capturingAnnounced = true
                self.queue.async { self.emit(.capturing) }
            }
        }
        self.mic = mic
        Self.dlog("mic capture started: \(mic.summary)")
        updateSummary()
    }

    private func buildSystem() {
        do {
            let output = try AudioDevice.defaultOutput()
            guard output.id != 0 else { throw CaptureError.noOutputDevice }
            let selfPID = pid_t(ProcessInfo.processInfo.processIdentifier)
            let system = try SystemAudioCapture(outputDevice: output, excludedPIDs: [selfPID] + options.excludedPIDs)
            guard let bus = mixBus else { return }
            try system.start { [weak bus] buffer, host in bus?.pushSystem(buffer, hostTime: host) }
            self.system = system
            Self.dlog("system capture started: \(system.summary); permission probe: \(String(describing: system.probeSystemAudioPermission()))")
        } catch {
            Self.dlog("system capture failed: \(error)")
            emit(.warning("System audio capture unavailable: \(error). Recording microphone only."))
        }
        updateSummary()
    }

    private func updateSummary() {
        captureSummary = [mic?.summary, system?.summary].compactMap { $0 }.joined(separator: ", ")
    }

    private func teardownCaptures() {
        if let mic { Self.dlog("mic teardown: callbacks=\(mic.callbackCount)") }
        if let system { Self.dlog("system teardown: callbacks=\(system.callbackCount)") }
        mic?.stop()
        mic = nil
        system?.stop()
        system = nil
    }

    // MARK: Device changes

    private func installDeviceListener() {
        guard deviceListener == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.devicesDidChange() }
        deviceListener = block
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = propertyAddress(selector)
            AudioObjectAddPropertyListenerBlock(.system, &address, queue, block)
        }
    }

    private func removeDeviceListener() {
        guard let block = deviceListener else { return }
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = propertyAddress(selector)
            AudioObjectRemovePropertyListenerBlock(.system, &address, queue, block)
        }
        deviceListener = nil
    }

    private func devicesDidChange() {
        guard state == .recording, !rebuildPending else { return }
        rebuildPending = true
        queue.asyncAfter(deadline: .now() + 0.4) { [self] in
            rebuildPending = false
            guard state == .recording else { return }
            let input = (try? AudioDevice.defaultInput()) ?? AudioDevice(id: 0)
            let output = (try? AudioDevice.defaultOutput()) ?? AudioDevice(id: 0)
            var changed = false
            if mic?.device != input {
                changed = true
                mic?.stop(); mic = nil
                do { try buildMic() } catch { emit(.warning("Microphone changed but could not be reopened: \(error)")) }
            }
            if system?.outputDevice != output {
                changed = true
                system?.stop(); system = nil
                buildSystem()
            }
            if changed { emit(.devicesChanged(captureSummary)) }
        }
    }

    // MARK: Periodic sampling (levels log, app detection) and permission heuristics

    private func startSampler() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        sampler = timer
    }

    private func sample() {
        let l = currentLevels
        Self.dlog(String(format: "levels: mic peak %.3f, system peak %.3f, mixed %.1fs, system frames %.1fs", l.mic, l.system, Double(l.framesCaptured) / (mixBus?.sampleRate ?? 48_000), Double(l.systemFrames) / (mixBus?.sampleRate ?? 48_000)))
        let me = pid_t(ProcessInfo.processInfo.processIdentifier)
        for process in AudioProcess.playing(excluding: [me]) where process.isKnownCallApp {
            appsSeen[process.displayName, default: 0] += 1
        }
    }

    private func scheduleSilenceCheck() {
        queue.asyncAfter(deadline: .now() + 8) { [self] in
            guard state == .recording, !permissionWarned, let system, system.callbackCount == 0 else { return }
            let me = pid_t(ProcessInfo.processInfo.processIdentifier)
            let playing = AudioProcess.playing(excluding: [me])
            if system.probeSystemAudioPermission() == false || !playing.isEmpty {
                permissionWarned = true
                let names = playing.map(\.displayName).joined(separator: ", ")
                emit(.warning(
                    "No system audio captured so far" + (names.isEmpty ? "" : " although \(names) is playing audio") +
                    ". If this persists, allow this app under System Settings > Privacy & Security > Screen & System Audio Recording > System Audio Recording Only, then stop and start again. " +
                    "Open: x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
                ))
            } else {
                scheduleSilenceCheck()
            }
        }
    }

    // MARK: Stop

    public func stop() {
        queue.async { [self] in
            guard state == .recording else { return }
            state = .stopping
            sampler?.cancel()
            sampler = nil
            removeDeviceListener()
            sample()
            teardownCaptures()
            mixBus?.finish()
            let duration = writer?.durationSeconds ?? 0
            let writeError = writer?.finish()
            let tempURL = currentURL
            writer = nil
            mixBus = nil

            var finalURL = tempURL
            if let tempURL, let start = startedAt {
                let app = KnownApps.preferredName(from: appsSeen) ?? "Call"
                let target = RecordingNamer.url(in: options.outputDirectory, date: start, app: app, ext: options.format.fileExtension)
                if target != tempURL, (try? FileManager.default.moveItem(at: tempURL, to: target)) != nil {
                    finalURL = target
                }
                RecordingNamer.writeSidecar(
                    for: finalURL ?? tempURL, start: start, end: Date(), duration: duration,
                    apps: appsSeen, capture: captureSummary, format: options.format
                )
            }
            state = .idle
            startedAt = nil
            currentURL = nil
            if let writeError { emit(.warning("Some audio may be missing: \(writeError)")) }
            if let finalURL { emit(.stopped(url: finalURL, duration: duration)) }
        }
    }

    private func emit(_ event: RecordingEvent) {
        Self.dlog("event: \(event)")
        onEvent?(event)
    }
}

/// Builds recording file names like `2026-10-29 14-05 Zoom.m4a`.
public enum RecordingNamer {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    public static func url(in directory: URL, date: Date, app: String, ext: String) -> URL {
        let base = "\(formatter.string(from: date)) \(sanitize(app))"
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = name.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return cleaned.isEmpty ? "Call" : cleaned
    }

    static func writeSidecar(for url: URL, start: Date, end: Date, duration: Double, apps: [String: Int], capture: String, format: OutputFormat) {
        let iso = ISO8601DateFormatter()
        let payload: [String: Any] = [
            "file": url.lastPathComponent,
            "start": iso.string(from: start),
            "end": iso.string(from: end),
            "durationSeconds": (duration * 10).rounded() / 10,
            "appsHeard": apps.keys.sorted(),
            "capture": capture,
            "format": format.rawValue,
            "recorder": "eko",
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
    }
}
