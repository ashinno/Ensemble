import Foundation
import Darwin

/// Monotonic clock based on `mach_absolute_time`, expressed in nanoseconds.
///
/// Every timestamp that crosses the network is expressed in the *host's* HostClock.
/// `ClockSyncManager` estimates the offset between two machines' HostClocks so a
/// receiver can convert host timestamps into its own timeline.
enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Current time in nanoseconds.
    static var nowNanos: Int64 { machToNanos(mach_absolute_time()) }

    /// Convert mach ticks (e.g. `AudioTimeStamp.mHostTime`) to nanoseconds without overflow.
    static func machToNanos(_ ticks: UInt64) -> Int64 {
        let tb = timebase
        if tb.numer == tb.denom { return Int64(ticks) }
        let numer = UInt64(tb.numer), denom = UInt64(tb.denom)
        let (q, r) = ticks.quotientAndRemainder(dividingBy: denom)
        return Int64(q * numer + (r * numer) / denom)
    }

    /// Convert nanoseconds back to mach ticks.
    static func nanosToMach(_ nanos: Int64) -> UInt64 {
        let tb = timebase
        let n = UInt64(max(0, nanos))
        if tb.numer == tb.denom { return n }
        let numer = UInt64(tb.numer), denom = UInt64(tb.denom)
        let (q, r) = n.quotientAndRemainder(dividingBy: numer)
        return q * denom + (r * denom) / numer
    }
}
