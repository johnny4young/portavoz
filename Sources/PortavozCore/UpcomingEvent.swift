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
    public let endDate: Date?
    public let platform: MeetingPlatform?
    public let recurrence: EventRecurrence?

    public init(
        id: String,
        title: String,
        startDate: Date,
        attendees: [String],
        endDate: Date? = nil,
        platform: MeetingPlatform? = nil,
        recurrence: EventRecurrence? = nil
    ) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.attendees = attendees
        self.endDate = endDate.flatMap { $0 > startDate ? $0 : nil }
        self.platform = platform
        self.recurrence = recurrence
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, startDate, attendees, endDate, platform, recurrence
    }

    /// Details are optional and tolerant: an older encoding lacks them, and a
    /// value a newer build added must not make a stored brief unreadable.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            title: try container.decode(String.self, forKey: .title),
            startDate: try container.decode(Date.self, forKey: .startDate),
            attendees: try container.decode([String].self, forKey: .attendees),
            endDate: try container.decodeIfPresent(Date.self, forKey: .endDate),
            platform: try? container.decodeIfPresent(MeetingPlatform.self, forKey: .platform),
            recurrence: try? container.decodeIfPresent(EventRecurrence.self, forKey: .recurrence))
    }

    /// The facts a brief preview shows; end, platform and recurrence only
    /// decorate Today, so editing them does not make a preview stale.
    public func hasSamePreviewFacts(as other: UpcomingEvent) -> Bool {
        id == other.id && title == other.title && startDate == other.startDate
            && attendees == other.attendees
    }

    /// Whole minutes between start and end, when the calendar gave an end.
    public var durationMinutes: Int? {
        endDate.map { Int($0.timeIntervalSince(startDate) / 60) }
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

/// The call service a calendar event links to, read from its URL, location
/// or notes. Names are brands and stay untranslated.
public enum MeetingPlatform: String, Codable, Sendable, CaseIterable {
    case googleMeet, zoom, teams, webex, facetime, whereby

    public var displayName: String {
        switch self {
        case .googleMeet: "Google Meet"
        case .zoom: "Zoom"
        case .teams: "Microsoft Teams"
        case .webex: "Webex"
        case .facetime: "FaceTime"
        case .whereby: "Whereby"
        }
    }

    private var hosts: [String] {
        switch self {
        case .googleMeet: ["meet.google.com"]
        case .zoom: ["zoom.us", "zoomgov.com"]
        case .teams: ["teams.microsoft.com", "teams.live.com"]
        case .webex: ["webex.com"]
        case .facetime: ["facetime.apple.com"]
        case .whereby: ["whereby.com"]
        }
    }

    /// The first platform whose host appears in any of the texts, in order.
    public static func detect(in texts: [String?]) -> MeetingPlatform? {
        for text in texts.compactMap({ $0?.lowercased() }) {
            if let match = allCases.first(where: { platform in
                platform.hosts.contains { Self.mentions(text, host: $0) }
            }) {
                return match
            }
        }
        return nil
    }

    /// The host as a whole domain or a subdomain of it, never a substring of
    /// a longer name ("notzoom.us").
    private static func mentions(_ text: String, host: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: host, range: searchRange) {
            let before = range.lowerBound == text.startIndex
                ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let isBoundary = { (character: Character?) in
                character.map { !($0.isLetter || $0.isNumber || $0 == "-") } ?? true
            }
            if isBoundary(before) && isBoundary(after) { return true }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }
}

/// How often a calendar event repeats.
public enum EventRecurrence: String, Codable, Sendable {
    case daily, weekly, monthly, yearly
}
