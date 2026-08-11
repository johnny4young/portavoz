import Foundation
import PortavozCore

/// Skills whose confirmed effect crosses Portavoz's process boundary and may
/// cause another app or service to sync meeting-derived material. They stay
/// separate from `LocalSkills` so its no-egress invariant remains executable.
public enum ExternalSkills {
    public static var definitions: [SkillDefinition] {
        [EmailRecapDraftSkill.definition]
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
