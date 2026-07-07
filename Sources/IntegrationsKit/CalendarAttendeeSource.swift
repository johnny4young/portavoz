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
