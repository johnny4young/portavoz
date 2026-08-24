import Foundation
import PortavozCore

/// Progressive evidence ownership for presentation surfaces. Lexical evidence
/// may render immediately; fused evidence is the immutable set used by answer
/// generation.
public enum AskEvidencePhase: String, Equatable, Sendable {
    case lexical
    case fused
}

public struct AskEvidenceUpdate: Equatable, Sendable {
    public let phase: AskEvidencePhase
    public let citations: [AskCitation]

    public init(
        phase: AskEvidencePhase,
        citations: [AskCitation]
    ) {
        self.phase = phase
        self.citations = citations
    }
}

public typealias AskEvidenceReceiver = @Sendable (AskEvidenceUpdate) async -> Void

/// Content-free terminal generation state. Cancellation remains an error so a
/// cancelled request cannot masquerade as an evidence-only successful answer.
public enum AskGenerationOutcome: String, Equatable, Sendable {
    case notRequested
    case generated
    case unavailable
    case failed
    case timedOut
}

/// One cumulative generated-answer snapshot. The application boundary admits
/// only monotonic, bounded snapshots before presentation can observe them.
public struct AskAnswerUpdate: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public typealias AskAnswerReceiver = @Sendable (AskAnswerUpdate) async -> Void

public enum AskRequestLimits {
    public static let maximumQuestionCharacters = 2_000
    public static let maximumQuestionUTF8Bytes = 16_000
    public static let maximumResultCount = 100
    public static let maximumAnswerCharacters = 8_000
    public static let maximumAnswerUTF8Bytes = 64_000
    public static let maximumAnswerSnapshots = 512
    public static let maximumMeetingTitleCharacters = 512
    public static let maximumCitationTextCharacters = 32_000
    public static let maximumSourceSegmentsPerCitation = 4_096
}

public enum AskRequestError: Error, Equatable, LocalizedError {
    case questionTooLong
    case resultLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .questionTooLong:
            "The question is too long."
        case .resultLimitExceeded:
            "The requested result count is too large."
        }
    }
}

private enum AskProgressiveStreamError: Error {
    case invalidEvidence
    case evidenceMismatch
}

struct AskGenerationResult: Sendable {
    let text: String?
    let outcome: AskGenerationOutcome
}

private struct AskCitationIdentity: Hashable {
    let meetingID: MeetingID
    let segmentID: UUID?
    let sourceSegmentIDs: [UUID]
    let timestamp: TimeInterval
    let transcriptRevision: Int
}

struct AskTimeoutError: Error {}

private enum AskTimedOperationResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
}

func withAskTimeout<Value: Sendable>(
    _ duration: Duration,
    onTimeout: @escaping @Sendable () async -> Void,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(
        of: AskTimedOperationResult<Value>.self
    ) { group in
        group.addTask {
            .value(try await operation())
        }
        group.addTask {
            try await Task.sleep(for: duration)
            return .timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else {
            throw CancellationError()
        }
        switch first {
        case .value(let value):
            return value
        case .timedOut:
            // The timeout must win the race before it closes publication.
            // Otherwise an operation completing at the same instant could be
            // returned while the gate was already stopped and be mislabeled
            // as an ordinary provider failure.
            await onTimeout()
            throw AskTimeoutError()
        }
    }
}

actor AskFirstEvidenceMilestone {
    private var didReach = false

    func reachIfNeeded(
        for citations: [AskCitation],
        trace: AskPipelineTrace
    ) {
        guard !didReach, !citations.isEmpty else { return }
        didReach = true
        trace.reach(.firstEvidence)
    }
}

actor AskFirstAnswerMilestone {
    private let trace: AskPipelineTrace
    private var didReach = false

    init(trace: AskPipelineTrace) {
        self.trace = trace
    }

    func reachIfNeeded() {
        guard !didReach else { return }
        didReach = true
        trace.reach(.firstToken)
    }
}

/// Owns the progressive protocol for one request. Retrieval and generation
/// providers remain replaceable, while this boundary prevents malformed,
/// duplicated, or late callbacks from reaching presentation.
actor AskProgressiveUpdateGate {
    private let limit: Int
    private let source: AskSourceScope
    private var isClosed = false
    private var sourceProtocolFailed = false
    private var fusedCitations: [AskCitation]?
    private var lastLexicalCitations: [AskCitation]?
    private var latestAnswerText: String?
    private var lastPublishedAnswerText: String?
    private var answerSnapshotCount = 0
    private var answerProtocolFailed = false

    init(limit: Int, source: AskSourceScope) {
        self.limit = limit
        self.source = source
    }

    func admitEvidence(_ update: AskEvidenceUpdate) -> AskEvidenceUpdate? {
        guard !isClosed else { return nil }
        guard sourceAdmits(update.citations) else {
            sourceProtocolFailed = true
            return nil
        }
        guard let citations = validatedCitations(update.citations) else {
            return nil
        }
        switch update.phase {
        case .lexical:
            guard fusedCitations == nil,
                  citations != lastLexicalCitations
            else { return nil }
            lastLexicalCitations = citations
            return AskEvidenceUpdate(phase: .lexical, citations: citations)
        case .fused:
            guard fusedCitations == nil else { return nil }
            fusedCitations = citations
            return AskEvidenceUpdate(phase: .fused, citations: citations)
        }
    }

    func finalizeEvidence(
        _ returned: [AskCitation]
    ) throws -> (citations: [AskCitation], update: AskEvidenceUpdate?) {
        guard !isClosed,
              !sourceProtocolFailed,
              sourceAdmits(returned),
              let citations = validatedCitations(returned)
        else { throw AskProgressiveStreamError.invalidEvidence }
        if let fusedCitations {
            guard fusedCitations == citations else {
                throw AskProgressiveStreamError.evidenceMismatch
            }
            return (fusedCitations, nil)
        }
        fusedCitations = citations
        return (
            citations,
            AskEvidenceUpdate(phase: .fused, citations: citations))
    }

    func admitAnswer(_ update: AskAnswerUpdate) -> AskAnswerUpdate? {
        guard !isClosed, !answerProtocolFailed else { return nil }
        answerSnapshotCount += 1
        guard answerSnapshotCount <= AskRequestLimits.maximumAnswerSnapshots,
              let text = validatedAnswer(update.text),
              latestAnswerText.map(text.hasPrefix) ?? true
        else {
            answerProtocolFailed = true
            latestAnswerText = nil
            lastPublishedAnswerText = nil
            return nil
        }
        guard text != latestAnswerText else { return nil }
        latestAnswerText = text
        guard shouldPublish(text) else { return nil }
        lastPublishedAnswerText = text
        return AskAnswerUpdate(text: text)
    }

    func finalizeAnswer(
        _ returned: String?
    ) -> (text: String?, update: AskAnswerUpdate?) {
        guard !isClosed, !answerProtocolFailed else { return (nil, nil) }
        guard let returned else {
            guard latestAnswerText == nil else {
                answerProtocolFailed = true
                return (nil, nil)
            }
            return (nil, nil)
        }
        guard let text = validatedAnswer(returned),
              latestAnswerText.map(text.hasPrefix) ?? true
        else {
            answerProtocolFailed = true
            return (nil, nil)
        }
        latestAnswerText = text
        guard text != lastPublishedAnswerText else { return (text, nil) }
        lastPublishedAnswerText = text
        return (text, AskAnswerUpdate(text: text))
    }

    func stopAnswering() {
        answerProtocolFailed = true
        latestAnswerText = nil
        lastPublishedAnswerText = nil
    }

    func close() {
        isClosed = true
    }

    private func validatedCitations(
        _ citations: [AskCitation]
    ) -> [AskCitation]? {
        guard citations.count <= limit else { return nil }
        var identities = Set<AskCitationIdentity>()
        for citation in citations {
            let identity = AskCitationIdentity(
                meetingID: citation.meetingID,
                segmentID: citation.segmentID,
                sourceSegmentIDs: citation.sourceSegmentIDs,
                timestamp: citation.timestamp,
                transcriptRevision: citation.transcriptRevision)
            guard citation.timestamp.isFinite,
                  citation.timestamp >= 0,
                  citation.transcriptRevision >= 0,
                  Self.isValidText(
                      citation.meetingTitle,
                      characterLimit:
                          AskRequestLimits.maximumMeetingTitleCharacters,
                      byteLimit:
                          AskRequestLimits.maximumMeetingTitleCharacters * 8),
                  Self.isValidText(
                      citation.text,
                      characterLimit:
                          AskRequestLimits.maximumCitationTextCharacters,
                      byteLimit:
                          AskRequestLimits.maximumCitationTextCharacters * 8),
                  citation.segmentID != nil || !citation.sourceSegmentIDs.isEmpty,
                  citation.sourceSegmentIDs.count
                      <= AskRequestLimits.maximumSourceSegmentsPerCitation,
                  Set(citation.sourceSegmentIDs).count
                      == citation.sourceSegmentIDs.count,
                  identities.insert(identity).inserted
            else { return nil }
        }
        return citations
    }

    private func sourceAdmits(_ citations: [AskCitation]) -> Bool {
        switch source {
        case .library:
            true
        case .meeting(let meetingID):
            citations.allSatisfy { $0.meetingID == meetingID }
        case .web:
            false
        }
    }

    private func validatedAnswer(_ value: String) -> String? {
        guard Self.isValidText(
            value,
            characterLimit: AskRequestLimits.maximumAnswerCharacters,
            byteLimit: AskRequestLimits.maximumAnswerUTF8Bytes)
        else { return nil }
        return value
    }

    private static func isValidText(
        _ value: String,
        characterLimit: Int,
        byteLimit: Int
    ) -> Bool {
        guard value.utf8.count <= byteLimit,
              value.count <= characterLimit
        else { return false }
        return value.contains { !$0.isWhitespace }
    }

    private func shouldPublish(_ text: String) -> Bool {
        guard let lastPublishedAnswerText else { return true }
        let growth = text.count - lastPublishedAnswerText.count
        return growth >= 24
            || text.last?.isPunctuation == true
            || text.last?.isNewline == true
    }
}
