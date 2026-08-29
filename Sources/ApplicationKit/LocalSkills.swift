import Foundation
import PortavozCore

/// The no-egress skill catalogue (D295).
///
/// Every skill here wraps a capability the product already has. A skill is a
/// *contract* over an existing use case — declared capabilities, typed
/// arguments, confirmation, idempotency, a durable receipt — not a second
/// implementation of the work. Nothing in this file performs meeting work
/// itself; each effect delegates.
public enum LocalSkills {
    public static var definitions: [SkillDefinition] {
        [
            ReminderDraftSkill.definition,
            RecapDraftSkill.definition,
            MeetingPackageExportSkill.definition,
            PreMeetingBriefSkill.definition
        ]
    }

    /// None of them may leave the Mac. Asserted rather than assumed, because
    /// the catalogue is where a future skill would quietly acquire egress.
    public static var isEntirelyLocal: Bool {
        definitions.allSatisfy { !$0.declaresExternalEffect }
    }

    /// One meeting subject, shared by every skill that acts on exactly one.
    ///
    /// Written once because two copies of a rule drift: the previous pair
    /// differed only in error type, and neither validated its arguments the way
    /// the reminder projection does. Malformed arguments are refused here too,
    /// so no effect ever runs on an unbounded or empty value.
    static func exactlyOneMeeting(
        in arguments: [SkillArgument],
        orThrow error: some Error
    ) throws -> MeetingID {
        try exactlyOne(in: arguments, orThrow: error) { argument in
            guard case .meeting(let id) = argument else { return nil }
            return id
        }
    }

    /// One trimmed free-text argument, for the skills whose subject is a string
    /// the app resolved — a calendar identifier, an export destination.
    static func exactlyOneText(
        in arguments: [SkillArgument],
        orThrow error: some Error
    ) throws -> String {
        try exactlyOne(in: arguments, orThrow: error) { argument in
            guard case .text(let value) = argument else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func exactlyOne<Value>(
        in arguments: [SkillArgument],
        orThrow error: some Error,
        _ project: (SkillArgument) -> Value?
    ) throws -> Value {
        guard arguments.allSatisfy(\.isValid) else { throw error }
        let matches = arguments.compactMap(project)
        guard matches.count == 1 else { throw error }
        return matches[0]
    }
}

// MARK: - Recap draft

public enum RecapDraftError: Error, Equatable, CategorizedFailure {
    case missingMeeting
    case noSummaryToRecap

    public var category: FailureCategory {
        switch self {
        case .missingMeeting: .critical
        case .noSummaryToRecap: .degradable
        }
    }
}

/// Reads the meeting and writes a recap draft the user still sends themselves.
public enum RecapDraftSkill {
    public static let id = "recap-draft"
    public static let version = 1

    public static let definition = SkillDefinition(
        id: id,
        version: version,
        capabilities: [.readMeetingMaterial, .writeLocalDraft],
        inputDataClasses: [.meetingDetails, .meetingSummary],
        subjectKind: .meeting,
        confirmationPolicy: .explicitPerProposal)

    public static func idempotencyKey(for meetingID: MeetingID) -> String {
        "\(id):\(meetingID.rawValue.uuidString)"
    }

    /// Exactly one meeting: a recap of two meetings is not a recap.
    public static func meeting(
        from arguments: [SkillArgument]
    ) throws -> MeetingID {
        try LocalSkills.exactlyOneMeeting(
            in: arguments,
            orThrow: RecapDraftError.missingMeeting)
    }
}

/// Supplies the material `RecapComposer` needs. The app owns the concrete
/// reader; this keeps the skill free of storage.
public protocol RecapMaterialReading: Sendable {
    func recapMaterial(
        for meetingID: MeetingID
    ) async throws -> (meeting: Meeting, speakers: [Speaker], summary: SummaryDraft)?
}

public protocol RecapDraftDelivering: Sendable {
    func deliver(_ recap: MeetingRecap) async throws
}

public struct RecapDraftEffect: SkillEffectPerforming {
    private let material: any RecapMaterialReading
    private let delivery: any RecapDraftDelivering

    public init(
        material: any RecapMaterialReading,
        delivery: any RecapDraftDelivering
    ) {
        self.material = material
        self.delivery = delivery
    }

    public func perform(_ proposal: SkillProposal) async throws {
        let meetingID = try RecapDraftSkill.meeting(from: proposal.arguments)
        guard let source = try await material.recapMaterial(for: meetingID) else {
            throw RecapDraftError.noSummaryToRecap
        }
        // The existing composer stays the only place that decides recap text.
        try await delivery.deliver(RecapComposer.compose(
            meeting: source.meeting,
            speakers: source.speakers,
            summary: source.summary))
    }
}

// MARK: - Meeting package export

public enum MeetingPackageExportError: Error, Equatable, CategorizedFailure {
    case missingMeeting
    case missingDestination

    public var category: FailureCategory { .critical }
}

/// Writes a `.portavoz` package to a destination the user already chose.
///
/// This is the one local skill declaring `writeLocalFile`, which is
/// irreversible, so it can never be covered by a standing rule.
public enum MeetingPackageExportSkill {
    public static let id = "meeting-package-export"
    public static let version = 1

    public static let definition = SkillDefinition(
        id: id,
        version: version,
        capabilities: [.readMeetingMaterial, .writeLocalFile],
        inputDataClasses: [
            .meetingDetails,
            .meetingSummary,
            .transcript,
            .notes,
            .companionHistory,
            .selectedDestination
        ],
        subjectKind: .meeting,
        confirmationPolicy: .explicitPerProposal)

    /// Normalized exactly as `destination(from:)` normalizes it. Two callers
    /// passing "  /a  " and "/a" mean one write, and a key that disagreed with
    /// the projection would claim two slots for it — the drift the destination
    /// argument exists to prevent.
    public static func idempotencyKey(
        for meetingID: MeetingID,
        destination: String
    ) -> String {
        let normalized = destination
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(id):\(meetingID.rawValue.uuidString):\(normalized)"
    }

    public static func meeting(
        from arguments: [SkillArgument]
    ) throws -> MeetingID {
        try LocalSkills.exactlyOneMeeting(
            in: arguments,
            orThrow: MeetingPackageExportError.missingMeeting)
    }

    /// The destination the key is scoped by, read from the proposal itself.
    ///
    /// The key claims "this meeting, to this destination". That claim only
    /// holds if the destination the effect writes to is the one the key was
    /// built from, so both come from the same argument rather than the key
    /// naming a path the writer separately decides.
    public static func destination(
        from arguments: [SkillArgument]
    ) throws -> String {
        try LocalSkills.exactlyOneText(
            in: arguments,
            orThrow: MeetingPackageExportError.missingDestination)
    }
}

/// Writes package bytes to the destination the user chose. The destination is
/// resolved by the app before the proposal exists and travels *in* the
/// proposal, so a skill never picks a path and the writer never picks one
/// behind the confirmation's back.
public protocol MeetingPackageWriting: Sendable {
    func write(
        _ package: Data,
        for meetingID: MeetingID,
        to destination: String
    ) async throws
}

public struct MeetingPackageExportEffect: SkillEffectPerforming {
    private let export: ExportMeetingBundle
    private let destination: any MeetingPackageWriting

    public init(
        export: ExportMeetingBundle,
        destination: any MeetingPackageWriting
    ) {
        self.export = export
        self.destination = destination
    }

    public func perform(_ proposal: SkillProposal) async throws {
        let meetingID = try MeetingPackageExportSkill.meeting(
            from: proposal.arguments)
        let path = try MeetingPackageExportSkill.destination(
            from: proposal.arguments)
        // Audio stays out: this tier is text-only, and including it would make
        // one confirmation move far more than the user previewed.
        let package = try await export.execute(ExportMeetingBundleRequest(
            meetingID: meetingID,
            includeAudio: false))
        try await destination.write(package, for: meetingID, to: path)
    }
}

// MARK: - Pre-meeting brief

public enum PreMeetingBriefError: Error, Equatable, CategorizedFailure {
    case missingEvent

    public var category: FailureCategory { .critical }
}

/// Prepares the brief for one upcoming calendar event.
public enum PreMeetingBriefSkill {
    public static let id = "pre-meeting-brief"
    public static let version = 1

    public static let definition = SkillDefinition(
        id: id,
        version: version,
        capabilities: [.readMeetingMaterial, .writeLocalDraft],
        inputDataClasses: [
            .calendarEvent,
            .meetingDetails,
            .meetingSummary,
            .transcript
        ],
        subjectKind: .calendarEvent,
        confirmationPolicy: .explicitPerProposal)

    /// The same bounded action when an exact current standing rule, rather
    /// than a per-proposal confirmation, supplies authority. Keeping the
    /// confirmation policy on a separate immutable definition prevents an
    /// autonomous run from masquerading as a reviewed one-shot proposal.
    public static let standingRuleDefinition = SkillDefinition(
        id: id,
        version: version,
        capabilities: definition.capabilities,
        inputDataClasses: definition.inputDataClasses,
        subjectKind: definition.subjectKind,
        confirmationPolicy: .standingRule)

    public static func idempotencyKey(forEvent identifier: String) -> String {
        "\(id):\(identifier)"
    }

    public static func event(
        from arguments: [SkillArgument]
    ) throws -> String {
        try LocalSkills.exactlyOneText(
            in: arguments,
            orThrow: PreMeetingBriefError.missingEvent)
    }
}

/// Resolves the event a proposal refers to. The app owns calendar access, so
/// the skill receives an already-resolved event rather than reaching for
/// EventKit.
public protocol UpcomingEventResolving: Sendable {
    func upcomingEvent(matching identifier: String) async throws -> UpcomingEvent?
}

public protocol MeetingBriefDelivering: Sendable {
    func deliver(_ brief: MeetingBrief) async throws
}

public struct PreMeetingBriefEffect: SkillEffectPerforming {
    private let material: MeetingBrief
    private let delivery: any MeetingBriefDelivering

    public init(
        material: MeetingBrief,
        delivery: any MeetingBriefDelivering
    ) {
        self.material = material
        self.delivery = delivery
    }

    public func perform(_ proposal: SkillProposal) async throws {
        let identifier = try PreMeetingBriefSkill.event(from: proposal.arguments)
        guard material.event.hasValidIdentity,
              identifier == material.event.id
        else { throw PreMeetingBriefError.missingEvent }
        // Preview composition already happened before confirmation. The effect
        // hands off that exact immutable artifact rather than re-reading Ask,
        // storage, or a model after the user approved it.
        try await delivery.deliver(material)
    }
}
