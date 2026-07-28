import Foundation

/// The LLM-expanded version of the user's own meeting notes (NOTES-001,
/// the Granola pattern): one separate document per meeting, built
/// FROM the raw timestamped notes plus the transcript. The raw
/// `ContextItem` notes are never modified — this is an additional artifact
/// the user can regenerate, and its fingerprint says exactly which inputs
/// produced it.
public struct EnhancedNote: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let meetingID: MeetingID
    /// The enhanced document. The user's original note text is preserved
    /// inside it (bold), expanded with transcript facts around each note's
    /// timestamp.
    public let markdown: String
    /// BCP-47 language the document was written in.
    public let language: String
    /// SHA-256 over the material (notes + transcript + method), so a
    /// regenerate with unchanged inputs can answer "already up to date".
    public let inputFingerprint: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        meetingID: MeetingID,
        markdown: String,
        language: String,
        inputFingerprint: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.meetingID = meetingID
        self.markdown = markdown
        self.language = language
        self.inputFingerprint = inputFingerprint
        self.createdAt = createdAt
    }
}
