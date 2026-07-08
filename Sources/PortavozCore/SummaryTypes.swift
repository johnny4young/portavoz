import Foundation

/// A template that reshapes a meeting into a specific output: standup
/// debrief, 1:1 notes, technical decision record, interview feedback.
public struct Recipe: Codable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let sections: [String]
    public let instructions: String

    public init(id: String, displayName: String, sections: [String], instructions: String) {
        self.id = id
        self.displayName = displayName
        self.sections = sections
        self.instructions = instructions
    }

    /// The default general-purpose meeting recipe.
    public static let general = Recipe(
        id: "general",
        displayName: "General meeting",
        sections: ["Overview", "Decisions", "Action Items", "Open Questions"],
        // Prompt de instrucciones de una línea.
        // swiftlint:disable:next line_length
        instructions: "Summarize the meeting faithfully. Attribute decisions and commitments to named speakers. Never invent content."
    )
}

/// The result of a summarization pass. Stored as an immutable versioned
/// snapshot — sharing always references a version, never a mutable row.
public struct SummaryDraft: Codable, Sendable {
    public let meetingID: MeetingID
    public let recipeID: String
    public let language: String
    public let markdown: String
    public let actionItems: [ActionItem]
    /// Identity of the summarized MATERIAL + method (D25), language
    /// EXCLUDED — a snapshot with the same fingerprint in another language
    /// is a valid translation pivot. nil on pre-jul-2026 snapshots (they
    /// simply never match).
    public var fingerprint: String?

    public init(
        meetingID: MeetingID, recipeID: String, language: String, markdown: String,
        actionItems: [ActionItem], fingerprint: String? = nil
    ) {
        self.meetingID = meetingID
        self.recipeID = recipeID
        self.language = language
        self.markdown = markdown
        self.actionItems = actionItems
        self.fingerprint = fingerprint
    }
}

public struct ActionItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public var text: String
    /// The speaker who owns the commitment, when attribution is possible.
    public var ownerSpeakerID: SpeakerID?
    public var isDone: Bool

    public init(id: UUID = UUID(), text: String, ownerSpeakerID: SpeakerID? = nil, isDone: Bool = false) {
        self.id = id
        self.text = text
        self.ownerSpeakerID = ownerSpeakerID
        self.isDone = isDone
    }
}
