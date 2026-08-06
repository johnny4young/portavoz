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
            PreMeetingBriefSkill.definition,
        ]
    }

    /// None of them may leave the Mac. Asserted rather than assumed, because
    /// the catalogue is where a future skill would quietly acquire egress.
    public static var isEntirelyLocal: Bool {
        definitions.allSatisfy { !$0.declaresExternalEffect }
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
        confirmationPolicy: .explicitPerProposal)

    public static func idempotencyKey(for meetingID: MeetingID) -> String {
        "\(id):\(meetingID.rawValue.uuidString)"
    }

    /// Exactly one meeting: a recap of two meetings is not a recap.
    public static func meeting(
        from arguments: [SkillArgument]
    ) throws -> MeetingID {
        let meetings = arguments.compactMap { argument -> MeetingID? in
            guard case .meeting(let id) = argument else { return nil }
            return id
        }
        guard meetings.count == 1 else { throw RecapDraftError.missingMeeting }
        return meetings[0]
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
        confirmationPolicy: .explicitPerProposal)

    public static func idempotencyKey(
        for meetingID: MeetingID,
        destination: String
    ) -> String {
        "\(id):\(meetingID.rawValue.uuidString):\(destination)"
    }

    public static func meeting(
        from arguments: [SkillArgument]
    ) throws -> MeetingID {
        let meetings = arguments.compactMap { argument -> MeetingID? in
            guard case .meeting(let id) = argument else { return nil }
            return id
        }
        guard meetings.count == 1 else {
            throw MeetingPackageExportError.missingMeeting
        }
        return meetings[0]
    }
}

/// Writes package bytes wherever the user chose. The destination is resolved
/// by the app before the proposal exists, so a skill never picks a path.
public protocol MeetingPackageWriting: Sendable {
    func write(_ package: Data, for meetingID: MeetingID) async throws
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
        // Audio stays out: this tier is text-only, and including it would make
        // one confirmation move far more than the user previewed.
        let package = try await export.execute(ExportMeetingBundleRequest(
            meetingID: meetingID,
            includeAudio: false))
        try await destination.write(package, for: meetingID)
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
        confirmationPolicy: .explicitPerProposal)

    public static func idempotencyKey(forEvent identifier: String) -> String {
        "\(id):\(identifier)"
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
    private let events: any UpcomingEventResolving
    private let brief: PrepareMeetingBrief
    private let delivery: any MeetingBriefDelivering

    public init(
        events: any UpcomingEventResolving,
        brief: PrepareMeetingBrief,
        delivery: any MeetingBriefDelivering
    ) {
        self.events = events
        self.brief = brief
        self.delivery = delivery
    }

    public func perform(_ proposal: SkillProposal) async throws {
        let identifiers = proposal.arguments.compactMap { argument -> String? in
            guard case .text(let value) = argument else { return nil }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard identifiers.count == 1,
              let event = try await events.upcomingEvent(
                  matching: identifiers[0])
        else { throw PreMeetingBriefError.missingEvent }
        try await delivery.deliver(try await brief.execute(event))
    }
}
