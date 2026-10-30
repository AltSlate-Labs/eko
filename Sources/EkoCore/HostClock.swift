import CoreAudio
import Foundation

/// mach_absolute_time helpers; HAL buffers are stamped with this clock.
public enum HostClock {
    static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func now() -> UInt64 { mach_absolute_time() }

    public static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    public static func ticks(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000 * Double(timebase.denom) / Double(timebase.numer))
    }

    static func hostTime(of stamp: UnsafePointer<AudioTimeStamp>) -> UInt64 {
        stamp.pointee.mFlags.contains(.hostTimeValid) ? stamp.pointee.mHostTime : now()
    }
}
