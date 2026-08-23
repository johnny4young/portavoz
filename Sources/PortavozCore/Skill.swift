import Foundation

/// What a skill is allowed to touch. Declared by the skill itself, never
/// inferred from the material it will act on.
public enum SkillCapability: String, Codable, Sendable, CaseIterable {
    /// Reads meeting material already on this Mac.
    case readMeetingMaterial = "read-meeting-material"
    /// Writes a draft the user still has to act on — a reminder draft, a copied
    /// recap. Reversible and local.
    case writeLocalDraft = "write-local-draft"
    /// Writes a file the user chose a destination for.
    case writeLocalFile = "write-local-file"
    /// Hands meeting-derived content outside Portavoz to a destination that
    /// may transmit or sync it. No skill in the no-egress tier may declare it.
    case sendRemote = "send-remote"

    /// Whether the capability can change anything outside Portavoz.
    public var isExternalEffect: Bool { self == .sendRemote }

    /// Whether the effect can be undone by the user without Portavoz's help.
    public var isReversible: Bool {
        switch self {
        case .readMeetingMaterial, .writeLocalDraft: true
        case .writeLocalFile, .sendRemote: false
        }
    }
}

/// How a proposal reaches execution.
public enum SkillConfirmationPolicy: String, Codable, Sendable {
    /// The user confirms this exact proposal after seeing its preview.
    case explicitPerProposal = "explicit-per-proposal"
    /// A narrowly scoped standing rule the user authored covers it. Legal only
    /// for reversible, local capabilities.
    case standingRule = "standing-rule"
}

/// Content categories a Skill is allowed to read for one proposal.
///
/// Capabilities describe what the effect may do; input data classes describe
/// what product material may influence it. Both are explicit ceilings so a
/// presentation can explain the real data boundary without inspecting content
/// or inferring it from a title.
public enum SkillInputDataClass: String, Codable, Sendable, CaseIterable {
    case meetingDetails = "meeting-details"
    case meetingSummary = "meeting-summary"
    case transcript
    case notes
    case companionHistory = "companion-history"
    case commitment
    case calendarEvent = "calendar-event"
    case selectedDestination = "selected-destination"
}

/// A structured, validated argument. Skills never receive free-form command
/// text: an argument is a typed value the policy can inspect, so transcript
/// content cannot become an instruction.
public enum SkillArgument: Equatable, Sendable {
    case meeting(MeetingID)
    case segment(UUID)
    case person(PersonID)
    case commitment(CommitmentID)
    case text(String)
    case date(Date)

    /// Free text is the only argument that can carry meeting content, and it is
    /// bounded so a proposal cannot smuggle a transcript into a preview.
    public static let maximumTextLength = 2_000

    public var isValid: Bool {
        switch self {
        case .text(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && value.count <= Self.maximumTextLength
        case .date(let value):
            return value.timeIntervalSinceReferenceDate.isFinite
        case .meeting, .segment, .person, .commitment:
            return true
        }
    }
}

/// The immutable contract a skill publishes about itself.
public struct SkillDefinition: Equatable, Sendable {
    public static let maximumCapabilityCount = 8
    public static let maximumInputDataClassCount = 12
    public static let maximumIDByteCount = 80

    public let id: String
    public let version: Int
    public let capabilities: Set<SkillCapability>
    public let inputDataClasses: Set<SkillInputDataClass>
    public let subjectKind: SkillSubject.Kind
    public let confirmationPolicy: SkillConfirmationPolicy

    public init(
        id: String,
        version: Int,
        capabilities: Set<SkillCapability>,
        inputDataClasses: Set<SkillInputDataClass>,
        subjectKind: SkillSubject.Kind,
        confirmationPolicy: SkillConfirmationPolicy
    ) {
        self.id = id
        self.version = version
        self.capabilities = capabilities
        self.inputDataClasses = inputDataClasses
        self.subjectKind = subjectKind
        self.confirmationPolicy = confirmationPolicy
    }

    public var declaresExternalEffect: Bool {
        capabilities.contains(where: \.isExternalEffect)
    }

    public var isReversible: Bool {
        capabilities.allSatisfy(\.isReversible)
    }

    public var isValid: Bool {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed == id,
              id.utf8.count <= Self.maximumIDByteCount,
              version >= 1,
              !capabilities.isEmpty,
              capabilities.count <= Self.maximumCapabilityCount,
              !inputDataClasses.isEmpty,
              inputDataClasses.count <= Self.maximumInputDataClassCount,
              inputDataClasses.contains(subjectInputDataClass)
        else { return false }
        // A standing rule may only cover work the user can undo alone.
        return confirmationPolicy == .explicitPerProposal || isReversible
    }

    private var subjectInputDataClass: SkillInputDataClass {
        switch subjectKind {
        case .meeting: .meetingDetails
        case .commitment: .commitment
        case .calendarEvent: .calendarEvent
        }
    }
}

/// One proposed execution. A proposal is inert: it carries what *would* happen
/// and nothing more.
public struct SkillProposal: Equatable, Sendable {
    public let id: UUID
    public let definition: SkillDefinition
    public let subject: SkillSubject
    /// The capabilities this specific proposal will actually use. It may use
    /// fewer than the definition declares, never more.
    public let requestedCapabilities: Set<SkillCapability>
    /// The exact data categories this proposal will read. As with
    /// capabilities, this may narrow the definition but never widen it.
    public let requestedInputDataClasses: Set<SkillInputDataClass>
    public let arguments: [SkillArgument]
    public let proposedAt: Date

    public init(
        id: UUID = UUID(),
        definition: SkillDefinition,
        subject: SkillSubject,
        requestedCapabilities: Set<SkillCapability>,
        requestedInputDataClasses: Set<SkillInputDataClass>,
        arguments: [SkillArgument],
        proposedAt: Date
    ) {
        self.id = id
        self.definition = definition
        self.subject = subject
        self.requestedCapabilities = requestedCapabilities
        self.requestedInputDataClasses = requestedInputDataClasses
        self.arguments = arguments
        self.proposedAt = proposedAt
    }
}

/// The exact durable identity captured when one reviewed proposal is
/// confirmed. Grouping the fields keeps every claiming adapter on one typed
/// contract instead of a long positional boundary.
public struct SkillExecutionConfirmation: Equatable, Sendable {
    public let proposalID: UUID
    public let skillID: String
    public let skillVersion: Int
    public let subject: SkillSubject
    public let offerKey: String
    public let idempotencyKey: String
    public let occurredAt: Date

    public init(
        proposalID: UUID,
        skillID: String,
        skillVersion: Int,
        subject: SkillSubject,
        offerKey: String,
        idempotencyKey: String,
        occurredAt: Date
    ) {
        self.proposalID = proposalID
        self.skillID = skillID
        self.skillVersion = skillVersion
        self.subject = subject
        self.offerKey = offerKey
        self.idempotencyKey = idempotencyKey
        self.occurredAt = occurredAt
    }
}

/// Where a proposal is in its life. `proposed` and `previewed` have produced no
/// effect of any kind; `dismissed` is terminal from either.
public enum SkillExecutionState: String, Codable, Sendable {
    case proposed
    case previewed
    case confirmed
    case executing
    case succeeded
    case failed
    case dismissed

    /// Whether an effect may have happened by the time a state is reached.
    public var mayHaveActed: Bool {
        switch self {
        case .proposed, .previewed, .dismissed: false
        case .confirmed, .executing, .succeeded, .failed: true
        }
    }
}

/// A bounded review lens over durable execution state. Proposal discovery is
/// deliberately absent: proposals do not yet have one central durable owner,
/// so a control center must not fabricate that queue from whichever surface
/// happens to be open.
public enum SkillExecutionReviewScope: String, CaseIterable, Hashable, Sendable {
    /// Every newest durable execution projection.
    case recent
    /// Confirmed by the user but not yet begun.
    case waiting
    /// Failed, interrupted, or written by a newer build in an unknown state.
    case needsAttention = "needs-attention"
    /// Successfully finished or cancelled before handoff.
    case completed
}

public struct SkillExecution: Equatable, Sendable {
    public let proposalID: UUID
    public let state: SkillExecutionState
    /// Stable across retries of the same proposal, so a repeat cannot duplicate
    /// an effect.
    public let idempotencyKey: String
    public let attempt: Int
    public let updatedAt: Date

    public init(
        proposalID: UUID,
        state: SkillExecutionState,
        idempotencyKey: String,
        attempt: Int,
        updatedAt: Date
    ) {
        self.proposalID = proposalID
        self.state = state
        self.idempotencyKey = idempotencyKey
        self.attempt = attempt
        self.updatedAt = updatedAt
    }
}

/// Why a proposal was refused. Every case is a refusal to act, never a
/// downgrade to a weaker action.
public enum SkillAdmissionRefusal: String, Equatable, Sendable {
    case invalidDefinition = "invalid-definition"
    case invalidArgument = "invalid-argument"
    case allSkillsPaused = "all-skills-paused"
    case skillDisabled = "skill-disabled"
    case undeclaredCapability = "undeclared-capability"
    case noRequestedCapability = "no-requested-capability"
    case noRequestedInputDataClass = "no-requested-input-data-class"
    case undeclaredInputDataClass = "undeclared-input-data-class"
    case invalidSubject = "invalid-subject"
    case egressNotPermitted = "egress-not-permitted"
    case confirmationMissing = "confirmation-missing"
    case standingRuleCannotCoverIrreversibleWork =
        "standing-rule-cannot-cover-irreversible-work"
    case staleProposal = "stale-proposal"
}

public enum SkillAdmission: Equatable, Sendable {
    case admitted
    case refused(SkillAdmissionRefusal)
}

/// Pure admission policy for confirmed skill execution.
///
/// The threat this exists for: a transcript is text written by other people,
/// and a model reads it. Nothing a transcript says may widen what a skill can
/// do. The policy therefore looks only at the skill's own declared contract and
/// the user's own confirmation — never at the material the skill will act on.
/// Arguments are typed values, so there is no free-form command for injected
/// text to inhabit.
public enum SkillAdmissionPolicy {
    /// A proposal the user has not confirmed within this window is stale and
    /// must be proposed again rather than silently executed later.
    public static let confirmationValidity: TimeInterval = 15 * 60

    public static func admit(
        _ proposal: SkillProposal,
        isConfirmedByUser: Bool,
        egressIsPermitted: Bool,
        executionPolicy: SkillExecutionPolicy = SkillExecutionPolicy(),
        at now: Date
    ) -> SkillAdmission {
        guard proposal.definition.isValid else {
            return .refused(.invalidDefinition)
        }
        guard !executionPolicy.isPaused else {
            return .refused(.allSkillsPaused)
        }
        guard executionPolicy.isIndividuallyEnabled(
            skillID: proposal.definition.id
        ) else {
            return .refused(.skillDisabled)
        }
        guard proposal.arguments.allSatisfy(\.isValid) else {
            return .refused(.invalidArgument)
        }
        guard proposal.subject.isValid,
              proposal.subject.kind == proposal.definition.subjectKind,
              proposal.subject.isRepresented(in: proposal.arguments)
        else { return .refused(.invalidSubject) }
        if let refusal = requestContractRefusal(for: proposal) {
            return .refused(refusal)
        }

        let sendsRemote = proposal.requestedCapabilities
            .contains(where: \.isExternalEffect)
        if sendsRemote && !egressIsPermitted {
            return .refused(.egressNotPermitted)
        }

        switch proposal.definition.confirmationPolicy {
        case .standingRule:
            // Re-checked here and not only at definition time, because the
            // requested subset is what will actually run.
            guard proposal.requestedCapabilities.allSatisfy(\.isReversible)
            else {
                return .refused(.standingRuleCannotCoverIrreversibleWork)
            }
            return .admitted
        case .explicitPerProposal:
            guard isConfirmedByUser else {
                return .refused(.confirmationMissing)
            }
            let age = now.timeIntervalSince(proposal.proposedAt)
            guard age >= 0, age <= confirmationValidity else {
                return .refused(.staleProposal)
            }
            return .admitted
        }
    }

    private static func requestContractRefusal(
        for proposal: SkillProposal
    ) -> SkillAdmissionRefusal? {
        guard !proposal.requestedCapabilities.isEmpty else {
            return .noRequestedCapability
        }
        guard !proposal.requestedInputDataClasses.isEmpty else {
            return .noRequestedInputDataClass
        }
        // The declaration is the ceiling. A proposal may narrow it, never widen
        // it — this is the check that transcript content cannot defeat.
        guard proposal.requestedCapabilities
            .isSubset(of: proposal.definition.capabilities)
        else { return .undeclaredCapability }
        guard proposal.requestedInputDataClasses
            .isSubset(of: proposal.definition.inputDataClasses)
        else { return .undeclaredInputDataClass }
        return nil
    }
}
