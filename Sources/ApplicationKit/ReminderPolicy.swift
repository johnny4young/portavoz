import Foundation
import PortavozCore

/// Decides WHEN the pre-meeting banner fires. Pure so tests pin it: the
/// next not-yet-started event whose start falls inside the lead window and
/// that wasn't already announced this session. Lead 0 = feature off.
public enum ReminderPolicy {
    public static func dueEvent(
        events: [UpcomingEvent],
        now: Date,
        leadMinutes: Int,
        alreadyReminded: Set<String>
    ) -> UpcomingEvent? {
        guard leadMinutes > 0 else { return nil }
        return events
            .filter { event in
                event.startDate > now
                    && event.startDate.timeIntervalSince(now) <= Double(leadMinutes) * 60
                    && !alreadyReminded.contains(event.id)
            }
            .min { lhs, rhs in
                if lhs.startDate == rhs.startDate { return lhs.id < rhs.id }
                return lhs.startDate < rhs.startDate
            }
    }
}
