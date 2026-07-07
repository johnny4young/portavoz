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

// Recipe, SummaryDraft and ActionItem moved to PortavozCore in M5 so
// StorageKit can persist them without a Kit-to-Kit dependency.
