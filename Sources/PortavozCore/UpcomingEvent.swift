import Foundation

/// A calendar event reduced to the neutral facts used by meeting preparation,
/// reminders, and recording context. Platform calendar adapters create this
/// value without leaking EventKit into domain or application policy.
public struct UpcomingEvent:
    Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Keeps an opaque provider reference bounded before it enters a Skill
    /// argument or an EventKit lookup. The value is not otherwise parsed.
    public static let maximumIdentifierLength = 2_000

    /// Opaque platform identity for one calendar occurrence. It is never
    /// derived from user-visible content; adapters must omit events whose
    /// provider cannot supply a nonempty reference.
    public let id: String
    public let title: String
    public let startDate: Date
    public let attendees: [String]

    public init(
        id: String,
        title: String,
        startDate: Date,
        attendees: [String]
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.attendees = attendees
    }

    /// Boundary validation for platform and fixture adapters. The identifier
    /// remains byte-for-byte opaque; whitespace is inspected, never trimmed.
    public var hasValidIdentity: Bool {
        Self.isValidIdentity(id)
    }

    public static func isValidIdentity(_ identifier: String) -> Bool {
        guard identifier.utf8.prefix(maximumIdentifierLength + 1).count
                <= maximumIdentifierLength
        else { return false }
        return identifier.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
