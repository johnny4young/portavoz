import EventKit
import Foundation
import PortavozCore

/// Calendar attendees around a meeting's start time — candidate names
/// for `SpeakerNamer` (M6). Requires the user to grant calendar access
/// (TCC prompt on first use); denial just means an empty candidate list,
/// never an error surfaced to the naming flow.
public struct CalendarAttendeeSource: Sendable {
    public init() {}

    /// True when access is granted (requests it if undetermined).
    public static func requestAccess() async -> Bool {
        let store = EKEventStore()
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    /// True only when access is ALREADY granted — never prompts. The brief
    /// loads silently for users who granted calendar access (naming flow);
    /// nobody gets an unsolicited TCC dialog on app launch.
    public static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// True while the user was never asked — the sidebar shows a one-time
    /// "connect your calendar" affordance instead of silently showing nothing.
    public static var accessUndetermined: Bool {
        EKEventStore.authorizationStatus(for: .event) == .notDetermined
    }

    /// The rest of today's meetings plus tomorrow's (non-all-day, still
    /// ongoing or future), sorted by start — the sidebar's prep agenda.
    public func upcomingEvents() -> [UpcomingEvent] {
        guard Self.hasAccess else { return [] }
        let store = EKEventStore()
        let now = Date()
        let endOfTomorrow = Calendar.current.startOfDay(for: now)
            .addingTimeInterval(48 * 3600)
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-15 * 60),
            end: endOfTomorrow,
            calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
            .map(Self.upcoming(from:))
    }

    /// The next event, if any. Kept for callers that only need one.
    public func nextEvent() -> UpcomingEvent? {
        upcomingEvents().first
    }

    private static func upcoming(from event: EKEvent) -> UpcomingEvent {
        var names: [String] = []
        var seen = Set<String>()
        for participant in event.attendees ?? [] {
            guard
                !participant.isCurrentUser,
                participant.participantType == .person,
                let name = participant.name,
                !name.contains("@"),
                seen.insert(name.lowercased()).inserted
            else { continue }
            names.append(name)
        }
        return UpcomingEvent(
            title: event.title ?? "Meeting",
            startDate: event.startDate,
            attendees: names)
    }

    /// Names of attendees (and organizers) of events overlapping
    /// `date ± window`, deduplicated, current user excluded when the
    /// calendar marks them.
    public func attendees(
        around date: Date, window: TimeInterval = 30 * 60
    ) async -> [String] {
        guard await Self.requestAccess() else { return [] }
        let store = EKEventStore()
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-window),
            end: date.addingTimeInterval(window),
            calendars: nil)
        let events = store.events(matching: predicate)

        var names: [String] = []
        var seen = Set<String>()
        for event in events {
            for participant in event.attendees ?? [] {
                guard
                    !participant.isCurrentUser,
                    participant.participantType == .person,
                    let name = participant.name,
                    !name.contains("@"),  // raw addresses aren't names
                    seen.insert(name.lowercased()).inserted
                else { continue }
                names.append(name)
            }
        }
        return names
    }
}
