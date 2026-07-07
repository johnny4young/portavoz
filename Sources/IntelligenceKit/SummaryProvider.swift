import Foundation
import PortavozCore

/// Generates structured summaries. Implementations planned: Apple
/// Foundation Models (default, on-device), MLX local models, and BYOK
/// providers (Anthropic, OpenAI-compatible, Groq, OpenRouter). Local is
/// always the default; sending a transcript to a cloud provider is an
/// explicit, visibly-labeled user choice.
public protocol SummaryProvider: Sendable {
    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft
}

public struct SummaryRequest: Sendable {
    public let meetingID: MeetingID
    public let segments: [TranscriptSegment]
    public let speakers: [Speaker]
    public let recipe: Recipe
    /// BCP-47 tag for the summary output — a meeting held in English can be
    /// summarized in Spanish, preserving technical terms via the glossary.
    public var targetLanguage: String
    /// Terms to keep untranslated in the output (deploy, PR, rollback…).
    public var glossary: [String]

    public init(
        meetingID: MeetingID,
        segments: [TranscriptSegment],
        speakers: [Speaker],
        recipe: Recipe,
        targetLanguage: String = "en",
        glossary: [String] = []
    ) {
        self.meetingID = meetingID
        self.segments = segments
        self.speakers = speakers
        self.recipe = recipe
        self.targetLanguage = targetLanguage
        self.glossary = glossary
    }
}

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

    public init(meetingID: MeetingID, recipeID: String, language: String, markdown: String, actionItems: [ActionItem]) {
        self.meetingID = meetingID
        self.recipeID = recipeID
        self.language = language
        self.markdown = markdown
        self.actionItems = actionItems
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
