import CoreAudio
import Foundation

/// Error thrown by any Core Audio HAL call that returns a non-zero OSStatus.
public struct CoreAudioError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        "\(operation) failed with \(fourCharCode(status)) (\(status))"
    }

    /// True when the HAL refused because of a TCC (privacy) denial.
    public var isPermissionDenied: Bool { status == kAudioDevicePermissionsError }
}

/// Renders an OSStatus as its four-character code when printable, e.g. `'!hog'`.
public func fourCharCode(_ status: OSStatus) -> String {
    let n = UInt32(bitPattern: status)
    let bytes = [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)]
    if bytes.allSatisfy({ $0 >= 32 && $0 < 127 }), let s = String(bytes: bytes, encoding: .ascii) {
        return "'\(s)'"
    }
    return String(status)
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
    if status != noErr { throw CoreAudioError(status: status, operation: operation()) }
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

extension AudioObjectID {
    static var system: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    /// Reads a fixed-size (POD) property value.
    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        initial: T
    ) throws -> T {
        var address = propertyAddress(selector, scope: scope, element: element)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        try withUnsafeMutablePointer(to: &value) { pointer in
            try check(
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, pointer),
                "get \(fourCharCode(OSStatus(bitPattern: selector))) on object \(self)"
            )
        }
        return value
    }

    /// Reads a variable-length array property.
    func readArray<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        placeholder: T
    ) throws -> [T] {
        var address = propertyAddress(selector, scope: scope, element: element)
        var size: UInt32 = 0
        try check(
            AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size),
            "get size of \(fourCharCode(OSStatus(bitPattern: selector))) on object \(self)"
        )
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var values = [T](repeating: placeholder, count: count)
        try values.withUnsafeMutableBufferPointer { buffer in
            try check(
                AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer.baseAddress!),
                "get \(fourCharCode(OSStatus(bitPattern: selector))) on object \(self)"
            )
        }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    /// Reads a CFString property.
    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        var address = propertyAddress(selector, scope: scope, element: element)
        var value: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value),
            "get string \(fourCharCode(OSStatus(bitPattern: selector))) on object \(self)"
        )
        return value?.takeRetainedValue() as String? ?? ""
    }

    /// Channel count of each input stream of a device, in stream order.
    func inputStreamChannelCounts() throws -> [Int] {
        var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "get stream configuration size")
        guard size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, raw), "get stream configuration")
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// Translates a Unix PID to the HAL process object that represents it.
    static func processObject(forPID pid: pid_t) throws -> AudioObjectID {
        var address = propertyAddress(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        try check(
            AudioObjectGetPropertyData(.system, &address, UInt32(MemoryLayout<pid_t>.size), &pidValue, &size, &objectID),
            "translate pid \(pid) to process object"
        )
        return objectID
    }
}

/// A HAL audio device (input or output).
public struct AudioDevice: Equatable {
    public let id: AudioDeviceID

    public init(id: AudioDeviceID) { self.id = id }

    public static func defaultInput() throws -> AudioDevice {
        AudioDevice(id: try AudioObjectID.system.read(kAudioHardwarePropertyDefaultInputDevice, initial: AudioDeviceID(0)))
    }

    public static func defaultOutput() throws -> AudioDevice {
        AudioDevice(id: try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0)))
    }

    public var uid: String { (try? id.readString(kAudioDevicePropertyDeviceUID)) ?? "" }
    public var name: String { (try? id.readString(kAudioObjectPropertyName)) ?? "Unknown device" }
    public var nominalSampleRate: Double { (try? id.read(kAudioDevicePropertyNominalSampleRate, initial: 0.0)) ?? 0 }
    public var inputStreamChannelCounts: [Int] { (try? id.inputStreamChannelCounts()) ?? [] }
}
