import Foundation
import PortavozCore

/// A storage-independent instant result for Ask surfaces.
public struct AskSearchResult: Equatable, Sendable {
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let segmentID: UUID
    public let sourceSegmentIDs: [UUID]
    public let snippet: String
    public let timestamp: TimeInterval

    public init(
        meetingID: MeetingID,
        meetingTitle: String,
        segmentID: UUID,
        sourceSegmentIDs: [UUID]? = nil,
        snippet: String,
        timestamp: TimeInterval
    ) {
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.segmentID = segmentID
        self.sourceSegmentIDs = sourceSegmentIDs ?? [segmentID]
        self.snippet = snippet
        self.timestamp = timestamp
    }
}

/// One exact piece of meeting evidence. Presentation can navigate with the
/// aggregate identity and timestamp without receiving a storage record or an
/// IntelligenceKit passage.
public struct AskCitation: Equatable, Sendable {
    /// Stable visible retrieval-unit identity. It may be a split part or merge
    /// correction rather than an accepted segment.
    public let segmentID: UUID?
    public let sourceSegmentIDs: [UUID]
    public let meetingID: MeetingID
    public let meetingTitle: String
    public let timestamp: TimeInterval
    public let transcriptRevision: Int
    public let text: String

    public init(
        segmentID: UUID? = nil,
        sourceSegmentIDs: [UUID]? = nil,
        meetingID: MeetingID,
        meetingTitle: String,
        timestamp: TimeInterval,
        transcriptRevision: Int = 0,
        text: String
    ) {
        self.segmentID = segmentID
        self.sourceSegmentIDs = sourceSegmentIDs ?? segmentID.map { [$0] } ?? []
        self.meetingID = meetingID
        self.meetingTitle = meetingTitle
        self.timestamp = timestamp
        self.transcriptRevision = transcriptRevision
        self.text = text
    }
}

/// Answer text is optional by design: evidence remains useful when the local
/// generative model is unavailable or fails, and callers choose localized copy.
public struct AskMeetingAnswer: Equatable, Sendable {
    public let question: String
    public let generatedText: String?
    public let citations: [AskCitation]
    public let generationOutcome: AskGenerationOutcome

    public init(
        question: String,
        generatedText: String?,
        citations: [AskCitation],
        generationOutcome: AskGenerationOutcome? = nil
    ) {
        self.question = question
        self.generatedText = generatedText
        self.citations = citations
        self.generationOutcome = generationOutcome
            ?? (generatedText == nil ? .unavailable : .generated)
    }
}

/// One explicit source authority for a manual Ask request. `meeting` is an
/// exact aggregate identity, `library` is the complete local meeting corpus,
/// and `web` remains a separate authority that local meeting retrieval must
/// reject until a consented web adapter is installed.
public enum AskSourceScope: Equatable, Sendable {
    case library
    case meeting(MeetingID)
    case web
}

public enum AskSourcePolicyError: Error, Equatable, LocalizedError {
    case webUnavailable
    case meetingScopeUnavailable
    case graphFactsRequireLibrary
    case sourceEvidenceMismatch

    public var errorDescription: String? {
        switch self {
        case .webUnavailable:
            "Web answers are not available. No other source was searched."
        case .meetingScopeUnavailable:
            "This Ask adapter cannot search one meeting without widening scope."
        case .graphFactsRequireLibrary:
            "Graph facts require explicit Library scope."
        case .sourceEvidenceMismatch:
            "Ask returned evidence outside the selected source."
        }
    }
}

/// Retrieval is an internal capability of the application workflow. Real
/// composition uses the hybrid local adapter; tests can inject deterministic
/// evidence without downloading model assets.
public protocol AskMeetingRetrieving: Sendable {
    func search(query: String, limit: Int) async throws -> [AskSearchResult]
    func retrieve(question: String, limit: Int) async throws -> [AskCitation]

    func search(
        query: String,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskSearchResult]
    func retrieve(
        question: String,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskCitation]
    func retrieve(
        question: String,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation]

    func search(
        query: String,
        source: AskSourceScope,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskSearchResult]
    func retrieve(
        question: String,
        source: AskSourceScope,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation]
}

public extension AskMeetingRetrieving {
    func search(
        query: String,
        source: AskSourceScope,
        limit: Int,
        trace: AskPipelineTrace
    ) async throws -> [AskSearchResult] {
        guard source == .library else {
            throw source == .web
                ? AskSourcePolicyError.webUnavailable
                : AskSourcePolicyError.meetingScopeUnavailable
        }
        return try await search(query: query, limit: limit, trace: trace)
    }

    func retrieve(
        question: String,
        source: AskSourceScope,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        guard source == .library else {
            throw source == .web
                ? AskSourcePolicyError.webUnavailable
                : AskSourcePolicyError.meetingScopeUnavailable
        }
        return try await retrieve(
            question: question,
            limit: limit,
            trace: trace,
            onEvidence: onEvidence)
    }

    func search(
        query: String,
        limit: Int,
        trace _: AskPipelineTrace
    ) async throws -> [AskSearchResult] {
        try await search(query: query, limit: limit)
    }

    func retrieve(
        question: String,
        limit: Int,
        trace _: AskPipelineTrace
    ) async throws -> [AskCitation] {
        try await retrieve(question: question, limit: limit)
    }

    func retrieve(
        question: String,
        limit: Int,
        trace: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        let citations = try await retrieve(
            question: question,
            limit: limit,
            trace: trace)
        await onEvidence(AskEvidenceUpdate(
            phase: .fused,
            citations: citations))
        return citations
    }
}
