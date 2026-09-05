import Foundation
import PortavozCore

/// What a reminder draft actually contains, derived only from the proposal's
/// typed arguments.
///
/// Pure on purpose: this is the whole decision about what leaves Portavoz as a
/// draft, and it is decided before any platform framework is involved. The
/// delivery adapter receives this and adds nothing.
public struct ReminderDraft: Equatable, Sendable {
    public let title: String
    public let dueAt: Date?
    public let commitmentID: CommitmentID?

    public init(title: String, dueAt: Date?, commitmentID: CommitmentID?) {
        self.title = title
        self.dueAt = dueAt
        self.commitmentID = commitmentID
    }
}

public enum ReminderDraftProjectionError: Error, Equatable, CategorizedFailure {
    case missingTitle
    case ambiguousArguments

    public var category: FailureCategory { .critical }
}

/// The local, reversible, no-egress reminder draft skill.
public enum ReminderDraftSkill {
    public static let id = "reminder-draft"
    public static let version = 1

    /// Reads meeting material and writes a local draft. It deliberately does
    /// not declare `writeLocalFile`: a draft the user can delete is reversible,
    /// which is what lets a standing rule cover this skill at all.
    public static let definition = SkillDefinition(
        id: id,
        version: version,
        capabilities: [.readMeetingMaterial, .writeLocalDraft],
        inputDataClasses: [.commitment, .selectedDestination],
        subjectKind: .commitment,
        confirmationPolicy: .explicitPerProposal)

    /// The one intended effect for a commitment is one draft, so the same
    /// commitment retried claims the same slot rather than drafting twice.
    public static func idempotencyKey(for commitmentID: CommitmentID) -> String {
        "\(id):\(commitmentID.rawValue.uuidString)"
    }

    /// Projects typed arguments into a draft.
    ///
    /// Exactly one title and at most one due date; a second of either is
    /// ambiguous and refused rather than silently resolved, because guessing
    /// which one the user meant is how a draft ends up saying something they
    /// did not confirm.
    public static func draft(
        from arguments: [SkillArgument]
    ) throws -> ReminderDraft {
        var titles: [String] = []
        var dates: [Date] = []
        var commitments: [CommitmentID] = []
        for argument in arguments {
            guard argument.isValid else {
                throw ReminderDraftProjectionError.ambiguousArguments
            }
            switch argument {
            case .text(let value):
                titles.append(value.trimmingCharacters(in: .whitespacesAndNewlines))
            case .date(let value):
                dates.append(value)
            case .commitment(let value):
                commitments.append(value)
            case .meeting, .segment, .actionItem, .person:
                continue
            }
        }
        guard titles.count == 1, dates.count <= 1, commitments.count <= 1 else {
            throw titles.isEmpty
                ? ReminderDraftProjectionError.missingTitle
                : ReminderDraftProjectionError.ambiguousArguments
        }
        return ReminderDraft(
            title: titles[0],
            dueAt: dates.first,
            commitmentID: commitments.first)
    }
}

/// Delivers a projected draft to wherever the platform keeps reminders. The
/// app supplies the concrete adapter; ApplicationKit never imports EventKit.
public protocol ReminderDraftDelivering: Sendable {
    func deliver(_ draft: ReminderDraft) async throws
}

/// Binds the pure projection to a delivery adapter. Projection failures are
/// typed and never reach delivery, so a malformed proposal cannot produce a
/// half-written draft.
public struct ReminderDraftEffect: SkillEffectPerforming {
    private let delivery: any ReminderDraftDelivering

    public init(delivery: any ReminderDraftDelivering) {
        self.delivery = delivery
    }

    public func perform(_ proposal: SkillProposal) async throws {
        let draft = try ReminderDraftSkill.draft(from: proposal.arguments)
        try await delivery.deliver(draft)
    }
}
