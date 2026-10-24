import Foundation

/// Keeps durable deadline recovery from spinning while a drain cannot claim work.
/// A failed drain always retries after the backoff, because unscheduled pending
/// work has no deadline; the next successful empty drain ends the timer.
public enum ProcessingWakeSchedule {
    static let failedDrainBackoff: TimeInterval = 5

    public static func nextDate(
        scheduled: Date?,
        afterDrainFailure: Bool,
        at timestamp: Date
    ) -> Date? {
        guard afterDrainFailure else { return scheduled }
        let backoff = timestamp.addingTimeInterval(failedDrainBackoff)
        return max(scheduled ?? backoff, backoff)
    }
}
