import EventKit
import Foundation

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

    /// The next non-all-day event starting within `window` (events that
    /// began in the last 15 minutes still count). nil when none or no access.
    public func nextEvent(within window: TimeInterval = 12 * 3600) -> UpcomingEvent? {
        guard Self.hasAccess else { return nil }
        let store = EKEventStore()
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-15 * 60),
            end: now.addingTimeInterval(window),
            calendars: nil)
        let event = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .min { $0.startDate < $1.startDate }
        guard let event else { return nil }

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

/// The next calendar event, reduced to what a pre-meeting brief needs.
public struct UpcomingEvent: Sendable, Equatable {
    public let title: String
    public let startDate: Date
    public let attendees: [String]

    public init(title: String, startDate: Date, attendees: [String]) {
        self.title = title
        self.startDate = startDate
        self.attendees = attendees
    }
}
