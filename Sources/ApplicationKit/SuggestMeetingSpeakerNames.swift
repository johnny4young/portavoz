import Foundation
import PortavozCore

/// Trusted source material independently derived by the application workflow.
/// Generator-authored prose never crosses this boundary as evidence.
public enum MeetingNameSuggestionEvidence: Equatable, Sendable {
    case transcript(String)
    case calendarCandidate(String)
}

/// A verified display-name suggestion for one currently unnamed meeting
/// speaker. Suggestions are inert until the user explicitly accepts one.
public struct MeetingNameSuggestion: Equatable, Sendable {
    public let label: String
    public let name: String
    public let evidence: MeetingNameSuggestionEvidence

    public init(
        label: String,
        name: String,
        evidence: MeetingNameSuggestionEvidence
    ) {
        self.label = label
        self.name = name
        self.evidence = evidence
    }
}

/// Untrusted output from a concrete name generator. Evidence is deliberately
/// absent: the application workflow derives it from admitted local inputs.
public struct MeetingNameProposal: Equatable, Sendable {
    public let label: String
    public let name: String

    public init(label: String, name: String) {
        self.label = label
        self.name = name
    }
}

/// Supplies possible participant names around a meeting without exposing the
/// concrete calendar framework or its authorization state.
public protocol MeetingNameCandidateProviding: Sendable {
    func names(around date: Date) async -> [String]
}

/// Produces untrusted name proposals. The application workflow verifies every
/// result against the complete transcript and candidate set before returning it.
public protocol MeetingSpeakerNameProposing: Sendable {
    func proposeNames(
        segments: [TranscriptSegment],
        speakers: [Speaker],
        attendeeCandidates: [String]
    ) async throws -> [MeetingNameProposal]
}

public struct SuggestMeetingSpeakerNamesRequest: Sendable {
    public let meetingID: MeetingID
    /// The device owner's display name. Participants address the owner by
    /// name constantly, so an owner-name proposal for a remote speaker is
    /// almost always the model misreading who a mention belongs to.
    public let ownerName: String?

    public init(meetingID: MeetingID, ownerName: String? = nil) {
        self.meetingID = meetingID
        self.ownerName = ownerName
    }
}

public enum SuggestMeetingSpeakerNamesError: Error, Equatable, LocalizedError, Sendable {
    case meetingNotFound

    public var errorDescription: String? {
        switch self {
        case .meetingNotFound:
            "The meeting no longer exists."
        }
    }
}

/// Coordinates coherent meeting reads, calendar-backed candidates, generation,
/// and never-trust verification. It never mutates a speaker automatically.
public struct SuggestMeetingSpeakerNames: ApplicationUseCase {
    private let library: QueryMeetingLibrary
    private let candidates: any MeetingNameCandidateProviding
    private let proposer: any MeetingSpeakerNameProposing

    public init(
        library: QueryMeetingLibrary,
        candidates: any MeetingNameCandidateProviding,
        proposer: any MeetingSpeakerNameProposing
    ) {
        self.library = library
        self.candidates = candidates
        self.proposer = proposer
    }

    public func execute(
        _ request: SuggestMeetingSpeakerNamesRequest
    ) async throws -> [MeetingNameSuggestion] {
        guard let detail = try await library.detail(request.meetingID) else {
            throw SuggestMeetingSpeakerNamesError.meetingNotFound
        }
        let unnamedLabels = Set(detail.speakers.lazy.filter {
            !$0.isMe && $0.displayName == nil
        }.map(\.label))
        guard !unnamedLabels.isEmpty else { return [] }

        let attendeeCandidates = await candidates.names(around: detail.meeting.startedAt)
        let proposals = try await proposer.proposeNames(
            segments: detail.segments,
            speakers: detail.speakers,
            attendeeCandidates: attendeeCandidates)
        return Self.verified(
            proposals,
            transcriptLines: detail.segments.map(\.text),
            unnamedLabels: unnamedLabels,
            attendeeCandidates: attendeeCandidates,
            ownerName: request.ownerName,
            takenNames: detail.speakers.compactMap(\.displayName))
    }

    static func verified(
        _ proposals: [MeetingNameProposal],
        transcriptLines: [String],
        unnamedLabels: Set<String>,
        attendeeCandidates: [String],
        ownerName: String? = nil,
        takenNames: [String] = []
    ) -> [MeetingNameSuggestion] {
        let transcriptLines = transcriptLines.compactMap(PersonAliasNormalizer.displayName)
        let candidates = attendeeCandidates.compactMap(PersonAliasNormalizer.displayName)
        // The same proposed name on two DISTINCT eligible speakers is
        // evidence for neither: "the name appears in the transcript" cannot
        // pick between them, and the field failure mode is the owner's name
        // spreading over the cast. A repeat of one (label, name) pair, or a
        // proposal on an ineligible label ("Me", already named), does not
        // poison a valid one.
        var labelsByName: [String: Set<String>] = [:]
        for proposal in proposals {
            let label = proposal.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard unnamedLabels.contains(label),
                let name = PersonAliasNormalizer.displayName(proposal.name)
            else { continue }
            labelsByName[nameKey(name), default: []].insert(label)
        }
        let ambiguous = Set(labelsByName.filter { $0.value.count > 1 }.keys)
        let taken = Set(takenNames.compactMap {
            PersonAliasNormalizer.displayName($0).map(nameKey)
        })
        var admittedLabels: Set<String> = []
        var suggestions: [MeetingNameSuggestion] = []

        for proposal in proposals {
            let label = proposal.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = PersonAliasNormalizer.displayName(proposal.name),
                  unnamedLabels.contains(label),
                  !admittedLabels.contains(label),
                  !ambiguous.contains(nameKey(name)),
                  !taken.contains(nameKey(name)),
                  !isOwnerAddressed(name, owner: ownerName)
            else {
                continue
            }

            let evidence: MeetingNameSuggestionEvidence?
            if let line = transcriptLines.first(where: {
                PersonNameEvidenceMatcher.contains(name, in: $0)
            }) {
                evidence = .transcript(line)
            } else if let candidate = candidates.first(where: {
                PersonNameEvidenceMatcher.contains(name, in: $0)
            }) {
                evidence = .calendarCandidate(candidate)
            } else {
                evidence = nil
            }

            guard let evidence else { continue }
            admittedLabels.insert(label)
            suggestions.append(MeetingNameSuggestion(
                label: label,
                name: name,
                evidence: evidence))
        }
        return suggestions
    }

    /// Case- and diacritic-folded identity for a display name.
    private static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    /// A proposal that matches the owner's name — or is a 4+ character short
    /// form of its first token ("John" for "Johnny") — reads as participants
    /// addressing the owner, not as another person's identity. A genuine
    /// distinct participant sharing that prefix loses only the automatic
    /// suggestion, never the manual rename.
    static func isOwnerAddressed(_ name: String, owner: String?) -> Bool {
        guard let owner,
            let ownerNormalized = PersonAliasNormalizer.displayName(owner)
        else { return false }
        let proposalKey = nameKey(name)
        let ownerKey = nameKey(ownerNormalized)
        if proposalKey == ownerKey { return true }
        guard
            let proposalFirst = proposalKey
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first,
            let ownerFirst = ownerKey
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).first
        else { return false }
        if proposalFirst == ownerFirst { return true }
        return proposalFirst.count >= 4 && ownerFirst.hasPrefix(proposalFirst)
    }
}
