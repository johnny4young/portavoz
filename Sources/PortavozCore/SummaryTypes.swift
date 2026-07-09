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
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "Summarize the meeting faithfully. Attribute decisions and commitments to named speakers. Never invent content."
    )

    // Typed recipes (M13b): each reshapes the summary for one meeting kind.
    // Their ids double as the meeting-type classifier's label set.

    public static let standup = Recipe(
        id: "standup",
        displayName: "Standup",
        sections: ["Progress", "Blockers", "Next Up"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "This is a daily standup. Group progress by the person who reported it. Blockers get their own section even when only hinted at. Never invent content."
    )

    public static let oneOnOne = Recipe(
        id: "one-on-one",
        displayName: "1:1",
        sections: ["Topics", "Feedback", "Agreements"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "This is a one-on-one conversation. Capture the topics discussed, feedback exchanged in both directions, and the concrete agreements. Keep sensitive wording faithful. Never invent content."
    )

    public static let planning = Recipe(
        id: "planning",
        displayName: "Planning",
        sections: ["Goals", "Scope Decisions", "Risks", "Next Steps"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "This is a planning session. State the goals, what was decided in or out of scope, the risks raised, and the concrete next steps with owners. Never invent content."
    )

    public static let interview = Recipe(
        id: "interview",
        displayName: "Interview",
        sections: ["Background", "Strengths", "Concerns", "Next Steps"],
        // One-line prompt instruction.
        // swiftlint:disable:next line_length
        instructions: "This is an interview. Summarize the candidate's background, observed strengths, concerns raised, and agreed next steps. Attribute opinions to who voiced them. Never invent content."
    )

    public static let all: [Recipe] = [.general, .standup, .oneOnOne, .planning, .interview]

    public static func byID(_ id: String) -> Recipe? {
        all.first { $0.id == id }
    }
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
