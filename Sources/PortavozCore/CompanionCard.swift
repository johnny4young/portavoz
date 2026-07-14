import Foundation

/// One answered question the live Companion surfaced during a recording,
/// kept so it can be reviewed on the meeting afterward. `source` names who
/// produced the answer ("on-device" today; the BYOK provider when it
/// exists) — the disclosure D26 demands. Lives in Core (not IntelligenceKit)
/// because StorageKit persists it, mirroring `ContextItem`; the pipeline
/// that produces it stays in IntelligenceKit.
public struct CompanionCard: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case knowledge
        case context
    }

    public let id: UUID
    public let question: String
    /// Empty on a pure "asked you" ping — the question itself is the
    /// whole value; the UI hides the answer block.
    public let answer: String
    public let kind: Kind
    public let source: String
    /// True when the caption addressed the device owner BY NAME (D26's
    /// "asked you"): the card doubles as an attention ping.
    public let directed: Bool
    /// Seconds since the meeting started, aligning the card with the transcript.
    public let askedAt: TimeInterval

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        kind: Kind,
        source: String,
        directed: Bool = false,
        askedAt: TimeInterval
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.kind = kind
        self.source = source
        self.directed = directed
        self.askedAt = askedAt
    }
}
