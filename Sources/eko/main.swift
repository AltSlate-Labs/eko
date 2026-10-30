import AVFoundation
import EkoCore
import Foundation

func usage() -> Never {
    print("""
    eko — record system audio + microphone into one file

    usage: eko [--out DIR] [--wav] [--seconds N] [--mic-gain G] [--system-gain G]
           eko --devices      show default input/output devices
           eko --apps         show processes currently playing audio
           eko --watch        print call start/end detections (mic use by call apps)

    Stops on Ctrl-C (or after --seconds). Output: DIR/yyyy-MM-dd HH-mm <App>.m4a
    Default DIR: ~/Documents/CallRecordings
    """)
    exit(0)
}

var args = Array(CommandLine.arguments.dropFirst())
var options = RecordingOptions()
var maxSeconds: Double?

while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--out":
        guard !args.isEmpty else { usage() }
        options.outputDirectory = URL(fileURLWithPath: (args.removeFirst() as NSString).expandingTildeInPath, isDirectory: true)
    case "--wav": options.format = .wav
    case "--seconds":
        guard !args.isEmpty, let s = Double(args.removeFirst()) else { usage() }
        maxSeconds = s
    case "--mic-gain":
        guard !args.isEmpty, let g = Float(args.removeFirst()) else { usage() }
        options.micGain = g
    case "--system-gain":
        guard !args.isEmpty, let g = Float(args.removeFirst()) else { usage() }
        options.systemGain = g
    case "--devices":
        let i = try AudioDevice.defaultInput(), o = try AudioDevice.defaultOutput()
        print("input:  \(i.name) [\(i.uid)] \(Int(i.nominalSampleRate)) Hz, streams \(i.inputStreamChannelCounts)")
        print("output: \(o.name) [\(o.uid)] \(Int(o.nominalSampleRate)) Hz")
        exit(0)
    case "--apps":
        for p in AudioProcess.playing() { print("pid \(p.pid)  \(p.displayName)  (\(p.bundleID))  output") }
        for p in AudioProcess.usingMicrophone() { print("pid \(p.pid)  \(p.displayName)  (\(p.bundleID))  MIC") }
        exit(0)
    case "--watch":
        let detector = CallDetector()
        detector.onCallStarted = { print("call started: \($0)") }
        detector.onCallEnded = { print("call ended: \($0)") }
        detector.start()
        print("watching for call apps using the microphone… (Ctrl-C to quit); now: \(CallDetector.currentCallApp() ?? "none")")
        RunLoop.main.run()
    default: usage()
    }
}

func log(_ s: String) {
    let t = DateFormatter(); t.dateFormat = "HH:mm:ss"
    FileHandle.standardError.write("[\(t.string(from: Date()))] \(s)\n".data(using: .utf8)!)
}

let session = RecordingSession(options: options)
var stopping = false

session.onEvent = { event in
    switch event {
    case let .started(url, summary):
        log("Recording → \(url.path)")
        log("Capture: \(summary)")
        log("Press Ctrl-C to stop.")
    case .capturing: log("Audio is flowing.")
    case let .warning(msg): log("WARNING: \(msg)")
    case let .info(msg): log(msg)
    case let .devicesChanged(summary): log("Devices changed, capture rebuilt: \(summary)")
    case let .stopped(url, duration):
        log(String(format: "Saved %@ (%.1f s)", url.path, duration))
        exit(0)
    case let .failed(error):
        log("ERROR: \(error)")
        exit(1)
    }
}

func requestStop() {
    guard !stopping else { return }
    stopping = true
    log("Stopping…")
    session.stop()
}

signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigint.setEventHandler { requestStop() }
sigint.resume()
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { requestStop() }
sigterm.resume()

let meter = DispatchSource.makeTimerSource(queue: .main)
meter.schedule(deadline: .now() + 2, repeating: 2)
meter.setEventHandler {
    guard session.state == .recording else { return }
    let l = session.currentLevels
    func bar(_ v: Float) -> String {
        let n = Int(min(1, v) * 20)
        return String(repeating: "█", count: n) + String(repeating: "·", count: 20 - n)
    }
    log(String(format: "%6.0fs  mic %@ %.2f   system %@ %.2f", session.elapsed, bar(l.mic), l.mic, bar(l.system), l.system))
    if let maxSeconds, session.elapsed >= maxSeconds { requestStop() }
}
meter.resume()

session.start()
RunLoop.main.run()
