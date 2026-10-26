import Foundation

/// Keeps durable deadline recovery from spinning while a drain cannot claim work.
/// A failed drain always retries after the backoff: pending work without a retry
/// date is invisible to `scheduled`, and the next healthy drain restores it.
public enum ProcessingWakeSchedule {
    static let failedDrainBackoff: TimeInterval = 5

    public static func nextDate(
        scheduled: Date?,
        afterDrainFailure: Bool,
        at timestamp: Date
    ) -> Date? {
        afterDrainFailure ? timestamp.addingTimeInterval(failedDrainBackoff) : scheduled
    }
}
