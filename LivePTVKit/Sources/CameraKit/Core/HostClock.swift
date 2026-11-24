import Foundation

/// 🐱 Monotonic host clock in seconds (CLOCK_UPTIME_RAW, the same base as mach_absolute_time / CACurrentMediaTime).
/// 🐱 All host-side timestamps in the app (arrival, decode, analysis, display) use this clock so they can be
/// 🐱 subtracted from each other safely. It does not jump when the wall clock is adjusted.
public enum HostClock {
    @inline(__always)
    public static func now() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    /// 🐱 A (wall clock, host clock) pair captured at the same instant. Stored in session metadata so every
    /// 🐱 recorded host timestamp can be converted to absolute UTC time afterwards.
    public struct Anchor: Codable, Sendable, Equatable {
        public let wallClockUTC: Date
        public let hostTime: Double

        public init(wallClockUTC: Date = Date(), hostTime: Double = HostClock.now()) {
            self.wallClockUTC = wallClockUTC
            self.hostTime = hostTime
        }

        public func wallClock(forHostTime t: Double) -> Date {
            wallClockUTC.addingTimeInterval(t - hostTime)
        }
    }
}
