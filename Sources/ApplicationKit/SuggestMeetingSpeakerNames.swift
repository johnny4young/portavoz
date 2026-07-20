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

    public init(meetingID: MeetingID) {
        self.meetingID = meetingID
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
            attendeeCandidates: attendeeCandidates)
    }

    static func verified(
        _ proposals: [MeetingNameProposal],
        transcriptLines: [String],
        unnamedLabels: Set<String>,
        attendeeCandidates: [String]
    ) -> [MeetingNameSuggestion] {
        let transcriptLines = transcriptLines.compactMap(PersonAliasNormalizer.displayName)
        let candidates = attendeeCandidates.compactMap(PersonAliasNormalizer.displayName)
        var admittedLabels: Set<String> = []
        var suggestions: [MeetingNameSuggestion] = []

        for proposal in proposals {
            let label = proposal.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name = PersonAliasNormalizer.displayName(proposal.name),
                  unnamedLabels.contains(label),
                  !admittedLabels.contains(label)
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
}
