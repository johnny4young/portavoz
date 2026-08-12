import Foundation
import PortavozCore

/// Skills whose confirmed effect crosses Portavoz's process boundary and may
/// cause another app or service to sync meeting-derived material. They stay
/// separate from `LocalSkills` so its no-egress invariant remains executable.
public enum ExternalSkills {
    public static var definitions: [SkillDefinition] {
        [
            EmailRecapDraftSkill.definition,
            SecretGistPublishSkill.definition
        ]
    }

    public static var requiresExplicitEgress: Bool {
        definitions.allSatisfy {
            $0.declaresExternalEffect
                && $0.confirmationPolicy == .explicitPerProposal
        }
    }
}

public enum EmailRecapDraftError: Error, Equatable, CategorizedFailure {
    case missingMeeting
    case noSummaryToRecap

    public var category: FailureCategory {
        switch self {
        case .missingMeeting: .critical
        case .noSummaryToRecap: .degradable
        }
    }
}

/// Prepares one summary-derived recap for the system email composer.
/// Recipients are deliberately absent from the contract: Portavoz never
/// guesses an audience, and the user still reviews and sends in their email
/// application after this exact per-proposal handoff.
public enum EmailRecapDraftSkill {
    public static let id = "email-recap-draft"
    public static let version = 1

    public static let definition = SkillDefinition(
        id: id,
        version: version,
        capabilities: [.readMeetingMaterial, .sendRemote],
        inputDataClasses: [.meetingDetails, .meetingSummary],
        subjectKind: .meeting,
        confirmationPolicy: .explicitPerProposal)

    public static func idempotencyKey(for meetingID: MeetingID) -> String {
        "\(id):\(meetingID.rawValue.uuidString)"
    }

    public static func meeting(
        from arguments: [SkillArgument]
    ) throws -> MeetingID {
        try LocalSkills.exactlyOneMeeting(
            in: arguments,
            orThrow: EmailRecapDraftError.missingMeeting)
    }
}

public protocol EmailRecapDraftDelivering: Sendable {
    func deliver(_ recap: MeetingRecap) async throws
}

public struct EmailRecapDraftEffect: SkillEffectPerforming {
    private let material: any RecapMaterialReading
    private let delivery: any EmailRecapDraftDelivering

    public init(
        material: any RecapMaterialReading,
        delivery: any EmailRecapDraftDelivering
    ) {
        self.material = material
        self.delivery = delivery
    }

    public func perform(_ proposal: SkillProposal) async throws {
        let meetingID = try EmailRecapDraftSkill.meeting(
            from: proposal.arguments)
        guard let source = try await material.recapMaterial(for: meetingID)
        else { throw EmailRecapDraftError.noSummaryToRecap }
        try await delivery.deliver(RecapComposer.compose(
            meeting: source.meeting,
            speakers: source.speakers,
            summary: source.summary))
    }
}

/// The complete, immutable request body approved for one secret GitHub Gist.
/// The credential and resulting URL stay in the platform adapter; durable
/// Skill/privacy receipts therefore never copy either secret or meeting text.
public struct SecretGistDraft: Equatable, Sendable {
    public static let destinationHost = "api.github.com"

    public let meetingID: MeetingID
    public let markdown: String
    public let filename: String
    public let description: String

    public init(
        meetingID: MeetingID,
        markdown: String,
        filename: String,
        description: String
    ) {
        self.meetingID = meetingID
        self.markdown = markdown
        self.filename = filename
        self.description = description
    }

    public var isValid: Bool {
        !markdown.isEmpty
            && !filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && filename.hasSuffix(".md")
            && !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SecretGistPublishError: Error, Equatable, CategorizedFailure {
    case missingMeeting
    case invalidDraft
    /// A content-free egress receipt already exists before transport starts,
    /// so any provider/transport failure after that point is conservatively
    /// ambiguous and must never be retried automatically.
    case outcomeUnknown

    public var category: FailureCategory {
        switch self {
        case .missingMeeting, .invalidDraft: .critical
        case .outcomeUnknown: .external
        }
    }
}

/// Publishes only one already-rendered, already-approved secret Gist body.
public protocol SecretGistPublishing: Sendable {
    func publish(_ draft: SecretGistDraft) async throws -> URL
}

public enum SecretGistPublishSkill {
    public static let id = "secret-gist-publish"
    public static let version = 1

    public static let definition = SkillDefinition(
        id: id,
        version: version,
        capabilities: [.readMeetingMaterial, .sendRemote],
        inputDataClasses: [
            .meetingDetails,
            .meetingSummary,
            .transcript
        ],
        subjectKind: .meeting,
        confirmationPolicy: .explicitPerProposal)

    public static func idempotencyKey(for meetingID: MeetingID) -> String {
        "\(id):\(meetingID.rawValue.uuidString)"
    }

    public static func meeting(
        from arguments: [SkillArgument]
    ) throws -> MeetingID {
        try LocalSkills.exactlyOneMeeting(
            in: arguments,
            orThrow: SecretGistPublishError.missingMeeting)
    }
}

public struct SecretGistPublishEffect: SkillEffectPerforming {
    private let draft: SecretGistDraft
    private let publisher: any SecretGistPublishing

    public init(
        draft: SecretGistDraft,
        publisher: any SecretGistPublishing
    ) {
        self.draft = draft
        self.publisher = publisher
    }

    public func perform(_ proposal: SkillProposal) async throws {
        let meetingID = try SecretGistPublishSkill.meeting(
            from: proposal.arguments)
        guard draft.isValid, draft.meetingID == meetingID else {
            throw SecretGistPublishError.invalidDraft
        }
        _ = try await publisher.publish(draft)
    }
}
