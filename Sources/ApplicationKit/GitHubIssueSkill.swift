import Foundation
import PortavozCore

public typealias GitHubIssueRepository = GitHubRepository

/// One exact source excerpt that will be included in the reviewed issue body.
public struct GitHubIssueCitation: Equatable, Sendable, Identifiable {
    public let segmentID: UUID
    public let timestamp: TimeInterval
    public let speaker: String
    public let excerpt: String

    public var id: UUID { segmentID }

    public init(
        segmentID: UUID,
        timestamp: TimeInterval,
        speaker: String,
        excerpt: String
    ) {
        self.segmentID = segmentID
        self.timestamp = timestamp
        self.speaker = speaker
        self.excerpt = excerpt
    }
}

/// The immutable GitHub request material approved in one confirmation sheet.
/// Credentials and the returned URL never enter this value or durable receipts.
public struct GitHubIssueDraft: Equatable, Sendable {
    public static let destinationHost = "api.github.com"
    public static let maximumCitationCount = 8
    public static let maximumCitationLength = 400
    public static let maximumTitleLength = 240
    public static let maximumBodyLength = 20_000

    public let meetingID: MeetingID
    public let actionItemID: UUID
    public let repository: GitHubIssueRepository
    public let title: String
    public let body: String
    public let citations: [GitHubIssueCitation]

    public init(
        meetingID: MeetingID,
        actionItemID: UUID,
        repository: GitHubIssueRepository,
        title: String,
        body: String,
        citations: [GitHubIssueCitation]
    ) {
        self.meetingID = meetingID
        self.actionItemID = actionItemID
        self.repository = repository
        self.title = title
        self.body = body
        self.citations = citations
    }

    public var isValid: Bool {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedTitle.isEmpty
            && normalizedTitle == title
            && title.count <= Self.maximumTitleLength
            && !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.count <= Self.maximumBodyLength
            && !citations.isEmpty
            && citations.count <= Self.maximumCitationCount
            && citations.allSatisfy {
                $0.timestamp.isFinite
                    && $0.timestamp >= 0
                    && !$0.speaker.isEmpty
                    && !$0.excerpt.isEmpty
                    && $0.excerpt.count <= Self.maximumCitationLength
            }
    }
}

public enum GitHubIssueSkillError: Error, Equatable, CategorizedFailure {
    case invalidRepository
    case meetingOrSummaryNotFound
    case actionItemUnavailable
    case staleSummary
    case citationsUnavailable
    case invalidDraft
    /// Transport or provider handling began, so GitHub may have created the
    /// issue even when the caller did not receive or persist a success.
    case outcomeUnknown

    public var category: FailureCategory {
        switch self {
        case .invalidRepository: .recoverable
        case .meetingOrSummaryNotFound, .invalidDraft: .critical
        case .actionItemUnavailable, .staleSummary, .citationsUnavailable: .degradable
        case .outcomeUnknown: .external
        }
    }
}

public enum GitHubIssueCreateSkill {
    public static let id = "github-issue-create"
    public static let version = 1

    public static let definition = SkillDefinition(
        id: id,
        version: version,
        capabilities: [.readMeetingMaterial, .sendRemote],
        inputDataClasses: [.meetingDetails, .meetingSummary, .transcript],
        subjectKind: .meeting,
        confirmationPolicy: .explicitPerProposal)

    /// Dismissing the affordance is scoped to this action item, while execution
    /// also includes the repository because publishing to another repository is
    /// a different user intent.
    public static func offerKey(
        meetingID: MeetingID,
        actionItemID: UUID
    ) -> String {
        "\(id):\(meetingID.rawValue.uuidString):\(actionItemID.uuidString)"
    }

    public static func idempotencyKey(for draft: GitHubIssueDraft) -> String {
        "\(offerKey(meetingID: draft.meetingID, actionItemID: draft.actionItemID)):\(draft.repository.rawValue.lowercased())"
    }

    public static func proposal(
        id: UUID,
        draft: GitHubIssueDraft,
        proposedAt: Date
    ) -> SkillProposal {
        SkillProposal(
            id: id,
            definition: definition,
            subject: .meeting(draft.meetingID),
            requestedCapabilities: [.readMeetingMaterial, .sendRemote],
            requestedInputDataClasses: definition.inputDataClasses,
            arguments: [
                .meeting(draft.meetingID),
                .actionItem(draft.actionItemID),
                .text(draft.repository.rawValue)
            ],
            proposedAt: proposedAt)
    }

    static func material(
        from arguments: [SkillArgument]
    ) throws -> (
        meetingID: MeetingID,
        actionItemID: UUID,
        repository: GitHubIssueRepository
    ) {
        guard arguments.allSatisfy(\.isValid) else {
            throw GitHubIssueSkillError.invalidDraft
        }
        let meetings = arguments.compactMap { argument -> MeetingID? in
            guard case .meeting(let value) = argument else { return nil }
            return value
        }
        let actionItems = arguments.compactMap { argument -> UUID? in
            guard case .actionItem(let value) = argument else { return nil }
            return value
        }
        let repositories = arguments.compactMap { argument -> GitHubIssueRepository? in
            guard case .text(let value) = argument else { return nil }
            return GitHubIssueRepository(value)
        }
        guard meetings.count == 1,
              actionItems.count == 1,
              repositories.count == 1
        else { throw GitHubIssueSkillError.invalidDraft }
        return (meetings[0], actionItems[0], repositories[0])
    }
}

public struct PrepareGitHubIssueDraftRequest: Equatable, Sendable {
    public let meetingID: MeetingID
    public let actionItemID: UUID
    public let repository: String

    public init(
        meetingID: MeetingID,
        actionItemID: UUID,
        repository: String
    ) {
        self.meetingID = meetingID
        self.actionItemID = actionItemID
        self.repository = repository
    }
}

/// Builds one bounded, correction-aware issue draft from a coherent library
/// snapshot. No credential, receipt, policy mutation, or network adapter is
/// touched while the user is still reviewing it.
public struct PrepareGitHubIssueDraft: ApplicationUseCase {
    private let library: QueryMeetingLibrary

    public init(library: QueryMeetingLibrary) {
        self.library = library
    }

    public func execute(
        _ request: PrepareGitHubIssueDraftRequest
    ) async throws -> GitHubIssueDraft {
        guard let repository = GitHubIssueRepository(request.repository) else {
            throw GitHubIssueSkillError.invalidRepository
        }
        guard let detail = try await library.detail(request.meetingID),
              let summary = detail.summary
        else { throw GitHubIssueSkillError.meetingOrSummaryNotFound }
        guard detail.summaryCorrectionSource.matches(detail.correctionRevision) else {
            throw GitHubIssueSkillError.staleSummary
        }
        guard let item = summary.actionItems.first(where: {
            $0.id == request.actionItemID && !$0.isDone
        }) else { throw GitHubIssueSkillError.actionItemUnavailable }
        let matchingEvidence = summary.actionItemEvidence.filter {
            $0.actionItemID == request.actionItemID
        }
        guard matchingEvidence.count == 1 else {
            throw GitHubIssueSkillError.citationsUnavailable
        }
        let evidence = matchingEvidence[0]
        let resolution = evidence.resolveEvidence(
            currentTranscriptRevision: detail.meeting.transcriptRevision,
            segments: detail.segments)
        guard resolution.status == .current else {
            throw GitHubIssueSkillError.citationsUnavailable
        }
        let rows = try currentTranscriptRows(detail)
        let citations = try makeCitations(
            evidenceSegmentIDs: evidence.evidenceSegmentIDs,
            rows: rows,
            speakers: detail.speakers)
        let owner = item.ownerSpeakerID.flatMap { ownerID in
            detail.speakers.first(where: { $0.id == ownerID })
        }.map { $0.displayName ?? $0.label }
        let title = Self.title(item.text)
        let body = Self.body(
            meetingTitle: detail.meeting.title,
            owner: owner,
            language: summary.language,
            citations: citations)
        let draft = GitHubIssueDraft(
            meetingID: detail.meeting.id,
            actionItemID: item.id,
            repository: repository,
            title: title,
            body: body,
            citations: citations)
        guard draft.isValid else { throw GitHubIssueSkillError.invalidDraft }
        return draft
    }

    private func currentTranscriptRows(
        _ detail: MeetingLibraryDetail
    ) throws -> [MeetingTranscriptContent.Row] {
        let material: MeetingTranscriptBaseMaterial = detail.isRefinedTranscript
            ? .refined
            : .raw
        let corrections = detail.corrections.filter {
            $0.baseTranscriptRevision == detail.meeting.transcriptRevision
        }
        do {
            return try ComposeTranscript().execute(
                baseTranscriptRevision: detail.meeting.transcriptRevision,
                baseMaterial: material,
                segments: detail.segments,
                corrections: corrections).composed.rows
        } catch {
            throw GitHubIssueSkillError.citationsUnavailable
        }
    }

    private func makeCitations(
        evidenceSegmentIDs: [UUID],
        rows: [MeetingTranscriptContent.Row],
        speakers: [Speaker]
    ) throws -> [GitHubIssueCitation] {
        // Corrupt imports can contain duplicate speaker identities. Prefer the
        // first durable record rather than letting Dictionary's unique-key
        // initializer terminate the process before this fail-closed boundary.
        let speakersByID = speakers.reduce(
            into: [SpeakerID: Speaker]()) { speakersByID, speaker in
            if speakersByID[speaker.id] == nil {
                speakersByID[speaker.id] = speaker
            }
        }
        var selected: [MeetingTranscriptContent.Row] = []
        var seen: Set<UUID> = []
        for sourceID in evidenceSegmentIDs {
            let matches = rows.filter { $0.sourceSegmentIDs.contains(sourceID) }
            guard !matches.isEmpty else {
                throw GitHubIssueSkillError.citationsUnavailable
            }
            for row in matches where seen.insert(row.id).inserted {
                selected.append(row)
            }
        }
        let ordered = selected.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard ordered.count <= GitHubIssueDraft.maximumCitationCount else {
            throw GitHubIssueSkillError.citationsUnavailable
        }
        let citations = ordered.map { row in
            GitHubIssueCitation(
                segmentID: row.id,
                timestamp: max(0, row.startTime),
                speaker: row.speakerID.flatMap { speakersByID[$0] }
                    .map { $0.displayName ?? $0.label }
                    ?? "Unknown speaker",
                excerpt: Self.boundedSingleLine(
                    row.text,
                    limit: GitHubIssueDraft.maximumCitationLength))
        }
        guard !citations.isEmpty else {
            throw GitHubIssueSkillError.citationsUnavailable
        }
        return citations
    }

    private static func title(_ text: String) -> String {
        boundedSingleLine(text, limit: GitHubIssueDraft.maximumTitleLength)
    }

    private static func body(
        meetingTitle: String,
        owner: String?,
        language: String?,
        citations: [GitHubIssueCitation]
    ) -> String {
        let labels = GitHubIssueLabels.forLanguage(language)
        var lines = [
            "\(labels.meetingActionItem) **\(escapeMarkdown(meetingTitle))**."
        ]
        if let owner, !owner.isEmpty {
            lines.append("\(labels.owner): **\(escapeMarkdown(owner))**.")
        }
        lines.append("## \(labels.evidence)")
        lines.append(contentsOf: citations.map { citation in
            "- `\(timestamp(citation.timestamp))` **\(escapeMarkdown(citation.speaker))**: \(escapeMarkdown(citation.excerpt))"
        })
        lines.append("_\(labels.provenance)_")
        return lines.joined(separator: "\n\n")
    }

    private static func boundedSingleLine(_ text: String, limit: Int) -> String {
        let normalized = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        let prefixCount = max(0, limit - 3)
        return "\(normalized.prefix(prefixCount))..."
    }

    private static func escapeMarkdown(_ text: String) -> String {
        let reserved = CharacterSet(charactersIn: "\\`*_{}[]()<>#!|+")
        return text.unicodeScalars.reduce(into: "") { result, scalar in
            if reserved.contains(scalar) { result.append("\\") }
            result.unicodeScalars.append(scalar)
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let remainder = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainder)
        }
        return String(format: "%02d:%02d", minutes, remainder)
    }
}

/// Issue scaffolding follows the generated summary's language, not the app
/// locale. It is reviewed meeting content that may be shared with collaborators,
/// matching the existing recap-language boundary.
private struct GitHubIssueLabels {
    let meetingActionItem: String
    let owner: String
    let evidence: String
    let provenance: String

    static func forLanguage(_ rawValue: String?) -> Self {
        LanguageCode(rawValue) == .spanish ? .spanish : .english
    }

    static let english = Self(
        meetingActionItem: "Meeting action item from",
        owner: "Agreed owner",
        evidence: "Evidence",
        provenance: "Created by Portavoz after explicit review.")

    static let spanish = Self(
        meetingActionItem: "Tarea de reunión de",
        owner: "Responsable acordado",
        evidence: "Evidencia",
        provenance: "Creado por Portavoz después de una revisión explícita.")
}

public protocol GitHubIssuePublishing: Sendable {
    func publish(_ draft: GitHubIssueDraft) async throws -> URL
}

public struct GitHubIssueCreateEffect: SkillEffectPerforming {
    private let draft: GitHubIssueDraft
    private let publisher: any GitHubIssuePublishing

    public init(
        draft: GitHubIssueDraft,
        publisher: any GitHubIssuePublishing
    ) {
        self.draft = draft
        self.publisher = publisher
    }

    public func perform(_ proposal: SkillProposal) async throws {
        let material = try GitHubIssueCreateSkill.material(
            from: proposal.arguments)
        guard draft.isValid,
              material.meetingID == draft.meetingID,
              material.actionItemID == draft.actionItemID,
              material.repository == draft.repository
        else { throw GitHubIssueSkillError.invalidDraft }
        _ = try await publisher.publish(draft)
    }
}
