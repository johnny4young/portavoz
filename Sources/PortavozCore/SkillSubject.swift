import Foundation

/// The content-free owner of one Skill intent. Subject identity is part of the
/// exact proposal contract, but titles, previews, arguments, destinations, and
/// recipients are not.
public enum SkillSubject: Equatable, Sendable {
    case meeting(MeetingID)
    case commitment(CommitmentID)
    case calendarEvent(String)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case meeting
        case commitment
        case calendarEvent = "calendar-event"
    }

    public var kind: Kind {
        switch self {
        case .meeting: .meeting
        case .commitment: .commitment
        case .calendarEvent: .calendarEvent
        }
    }

    public var isValid: Bool {
        switch self {
        case .meeting, .commitment:
            true
        case .calendarEvent(let identifier):
            UpcomingEvent.isValidIdentity(identifier)
        }
    }

    /// The subject must be present in the proposal's typed arguments. Other
    /// arguments may narrow the effect (for example an export destination),
    /// but they can never replace its owner.
    public func isRepresented(in arguments: [SkillArgument]) -> Bool {
        let matches = arguments.filter { argument in
            switch (self, argument) {
            case (.meeting(let expected), .meeting(let actual)):
                expected == actual
            case (.commitment(let expected), .commitment(let actual)):
                expected == actual
            case (.calendarEvent(let expected), .text(let actual)):
                expected == actual
            default:
                false
            }
        }
        return matches.count == 1
    }
}

/// Source-compatible name for the offer authority introduced before subjects
/// also became part of exact execution proposals.
public typealias SkillOfferSubject = SkillSubject
