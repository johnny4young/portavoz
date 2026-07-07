import Foundation
import PortavozCore

/// Anything the user drops into a meeting while it happens — a link, a
/// typed note, a pasted stack trace, a handwritten note (iPad). Items are
/// timestamped so they interleave with the transcript and enrich the
/// summary: notes carry intent, the transcript carries facts.
public struct ContextItem: Codable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case note
        case link
        case codeSnippet
        case file
    }

    public let id: UUID
    public let meetingID: MeetingID
    public let kind: Kind
    public let content: String
    /// Seconds since the meeting started, aligning the item with the transcript.
    public let timestamp: TimeInterval

    public init(id: UUID = UUID(), meetingID: MeetingID, kind: Kind, content: String, timestamp: TimeInterval) {
        self.id = id
        self.meetingID = meetingID
        self.kind = kind
        self.content = content
        self.timestamp = timestamp
    }
}
