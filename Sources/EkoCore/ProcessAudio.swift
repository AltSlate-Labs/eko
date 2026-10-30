import AppKit
import CoreAudio
import Foundation

/// A process known to the audio HAL, with whether it is currently playing audio.
public struct AudioProcess: Equatable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String
    public let isRunningOutput: Bool
    /// True while the process has the microphone (or another input device) open.
    public let isRunningInput: Bool

    /// Friendly name used in recording file names.
    public var displayName: String {
        if let known = KnownApps.name(forBundleID: bundleID) { return known }
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, !name.isEmpty {
            return name
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? "Call"
    }

    public var isKnownCallApp: Bool { KnownApps.name(forBundleID: bundleID) != nil }

    /// All processes the HAL knows about.
    public static func all() throws -> [AudioProcess] {
        let ids = try AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, placeholder: AudioObjectID(0))
        return ids.compactMap { id in
            guard let pid = try? id.read(kAudioProcessPropertyPID, initial: pid_t(0)) else { return nil }
            let bundle = (try? id.readString(kAudioProcessPropertyBundleID)) ?? ""
            let output = (try? id.read(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            let input = (try? id.read(kAudioProcessPropertyIsRunningInput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: output != 0, isRunningInput: input != 0)
        }
    }

    /// Processes currently producing output audio, excluding the given PIDs.
    public static func playing(excluding pids: Set<pid_t> = []) -> [AudioProcess] {
        ((try? all()) ?? []).filter { $0.isRunningOutput && !pids.contains($0.pid) && !$0.bundleID.isEmpty }
    }

    /// Processes currently using an input device (microphone), excluding the given PIDs.
    public static func usingMicrophone(excluding pids: Set<pid_t> = []) -> [AudioProcess] {
        ((try? all()) ?? []).filter { $0.isRunningInput && !pids.contains($0.pid) && !$0.bundleID.isEmpty }
    }
}

/// Bundle identifiers of common call apps, mapped to the name used in file names.
public enum KnownApps {
    static let names: [String: String] = [
        "us.zoom.xos": "Zoom",
        "com.google.Chrome": "Chrome",
        "com.google.Chrome.canary": "Chrome",
        "com.apple.Safari": "Safari",
        "org.mozilla.firefox": "Firefox",
        "company.thebrowser.Browser": "Arc",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge",
        "com.microsoft.teams2": "Teams",
        "com.microsoft.teams": "Teams",
        "com.tinyspeck.slackmacgap": "Slack",
        "com.apple.FaceTime": "FaceTime",
        "com.hnc.Discord": "Discord",
        "com.cisco.webexmeetingsapp": "Webex",
        "com.webex.meetingmanager": "Webex",
        "com.skype.skype": "Skype",
        "net.whatsapp.WhatsApp": "WhatsApp",
        "com.loom.desktop": "Loom",
        "com.readdle.smartemail-Mac": "Spark",
        "com.around.Around": "Around",
    ]

    /// Apps that are primarily meeting clients get priority when several apps play audio at once.
    static let meetingPriority: [String] = ["Zoom", "Teams", "Webex", "FaceTime", "Discord", "Slack", "Skype", "WhatsApp"]

    /// Exact match, or a helper process of a known app (e.g. `com.google.Chrome.helper`).
    public static func name(forBundleID bundleID: String) -> String? {
        if let exact = names[bundleID] { return exact }
        for (key, name) in names where bundleID.hasPrefix(key + ".") { return name }
        return nil
    }

    /// Picks the best app name from a set of names seen during a recording.
    public static func preferredName(from seen: [String: Int]) -> String? {
        guard !seen.isEmpty else { return nil }
        for candidate in meetingPriority where seen[candidate] != nil { return candidate }
        return seen.max { a, b in a.value < b.value }?.key
    }
}
