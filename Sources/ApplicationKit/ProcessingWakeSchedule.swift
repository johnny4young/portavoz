import Foundation

/// Retry timing after a drain that could not claim work. A failed drain never
/// waits for the persisted deadline: pending work without a retry date is
/// invisible to it. Consecutive failures double the wait, up to twelve times the base.
public enum ProcessingWakeSchedule {
    public static let failedDrainBackoff: TimeInterval = 5

    /// 5, 10, 20, 40, then 60 seconds with the default base.
    public static func retryDate(
        afterConsecutiveFailures failures: Int,
        base: TimeInterval = failedDrainBackoff,
        at timestamp: Date
    ) -> Date {
        let doubled = base * Double(1 << min(max(failures, 1) - 1, 4))
        return timestamp.addingTimeInterval(min(doubled, base * 12))
    }
}
