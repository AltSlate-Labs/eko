// Try Sarvam speech-to-text (batch API, saaras:v4) on whole recordings, outside the app.
// The key is read from SARVAM_API_KEY (see .env); it is never printed.
//
//   set -a; . ./.env; set +a
//   swift scripts/sarvam-stt.swift <output folder> <recording.m4a>...
//
// Sends the audio to Sarvam. Writes each result as <name>-sarvam.json in the output folder.
import Foundation

let api = "https://api.sarvam.ai/speech-to-text/job/v1"
guard let key = ProcessInfo.processInfo.environment["SARVAM_API_KEY"], !key.isEmpty else {
    FileHandle.standardError.write("SARVAM_API_KEY is not set\n".data(using: .utf8)!)
    exit(2)
}
let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { print("usage: sarvam-stt.swift <output folder> <recording>..."); exit(2) }
let outDir = URL(fileURLWithPath: args[0], isDirectory: true)
let files = args.dropFirst().map { URL(fileURLWithPath: $0) }

struct Failure: Error, CustomStringConvertible { let description: String }

func call(_ method: String, _ url: String, json: [String: Any]? = nil) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    request.setValue(key, forHTTPHeaderField: "api-subscription-key")
    if let json {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw Failure(description: "\(method) \(url.replacingOccurrences(of: api, with: "…")): HTTP \(status) \(String(data: data, encoding: .utf8) ?? "")")
    }
    return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

let started = Date()
func say(_ text: String) { print(String(format: "[%4.0f s] ", Date().timeIntervalSince(started)) + text) }

do {
    // 1. Job: Roman-script output (translit), language auto-detected, timestamps and speakers.
    let job = try await call("POST", api, json: ["job_parameters": [
        "model": "saaras:v4", "mode": "translit", "language_code": "unknown",
        "with_timestamps": true, "with_diarization": true,
    ]])
    guard let id = job["job_id"] as? String else { throw Failure(description: "no job_id: \(job)") }
    say("job \(id) created")

    // 2. Upload each file to its presigned URL (Azure blob).
    let names = files.map(\.lastPathComponent)
    let links = try await call("POST", "\(api)/upload-files", json: ["job_id": id, "files": names])
    let urls = links["upload_urls"] as? [String: [String: Any]] ?? [:]
    for file in files {
        guard let target = urls[file.lastPathComponent]?["file_url"] as? String else {
            throw Failure(description: "no upload URL for \(file.lastPathComponent)")
        }
        var put = URLRequest(url: URL(string: target)!)
        put.httpMethod = "PUT"
        put.setValue("BlockBlob", forHTTPHeaderField: "x-ms-blob-type")
        put.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: put, fromFile: file)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure(description: "upload \(file.lastPathComponent): HTTP \(status)") }
        say("uploaded \(file.lastPathComponent) (\(((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) / 1_000_000) MB)")
    }

    // 3. Start, then poll until done.
    _ = try await call("POST", "\(api)/\(id)/start")
    say("started")
    var status: [String: Any] = [:]
    var last = ""
    while true {
        try await Task.sleep(nanoseconds: 10_000_000_000)
        status = try await call("GET", "\(api)/\(id)/status")
        let state = status["job_state"] as? String ?? "?"
        if state != last { say("state: \(state)"); last = state }
        if state == "Completed" || state == "Failed" || state == "PartiallyCompleted" { break }
        if Date().timeIntervalSince(started) > 3600 { throw Failure(description: "gave up after an hour") }
    }
    let details = status["job_details"] as? [[String: Any]] ?? []
    for d in details where d["state"] as? String != "Success" {
        say("file failed: \(d["error_message"] as? String ?? "?") \(d["inputs"] ?? "")")
    }

    // 4. Download the outputs, named after their inputs.
    var outputs: [(input: String, output: String)] = []
    for d in details where d["state"] as? String == "Success" {
        let input = ((d["inputs"] as? [[String: Any]])?.first?["file_name"] as? String) ?? "?"
        for o in d["outputs"] as? [[String: Any]] ?? [] { if let f = o["file_name"] as? String { outputs.append((input, f)) } }
    }
    guard !outputs.isEmpty else { throw Failure(description: "no outputs; state \(last)") }
    let downloads = try await call("POST", "\(api)/download-files", json: ["job_id": id, "files": outputs.map(\.output)])
    let durls = downloads["download_urls"] as? [String: [String: Any]] ?? [:]
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    for (input, output) in outputs {
        guard let link = durls[output]?["file_url"] as? String else { continue }
        let (data, _) = try await URLSession.shared.data(from: URL(string: link)!)
        let dest = outDir.appendingPathComponent((input as NSString).deletingPathExtension + "-sarvam.json")
        try data.write(to: dest, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
        say("saved \(dest.lastPathComponent) (\(data.count / 1000) KB)")
    }
} catch {
    say("error: \(error)")
    exit(1)
}
