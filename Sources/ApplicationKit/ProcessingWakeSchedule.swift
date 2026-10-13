import Foundation

/// Keeps durable deadline recovery from spinning while a drain cannot claim work.
public enum ProcessingWakeSchedule {
    public static func nextDate(
        scheduled: Date?,
        afterDrainFailure: Bool,
        at timestamp: Date
    ) -> Date? {
        guard let scheduled else { return nil }
        guard afterDrainFailure else { return scheduled }
        return max(scheduled, timestamp.addingTimeInterval(5))
    }
}
