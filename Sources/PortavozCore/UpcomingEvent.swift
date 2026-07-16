import Foundation

/// A calendar event reduced to the neutral facts used by meeting preparation,
/// reminders, and recording context. Platform calendar adapters create this
/// value without leaking EventKit into domain or application policy.
public struct UpcomingEvent: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { title + startDate.timeIntervalSince1970.description }

    public let title: String
    public let startDate: Date
    public let attendees: [String]

    public init(title: String, startDate: Date, attendees: [String]) {
        self.title = title
        self.startDate = startDate
        self.attendees = attendees
    }
}
