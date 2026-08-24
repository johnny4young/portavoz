import Foundation
import IntelligenceKit
import PortavozCore

/// The exact remote turn currently being answered during an explicitly
/// enabled interview-assist session. Detection is deterministic; no model is
/// allowed to rewrite the question before the user sees or submits it.
public struct InterviewQuestion: Equatable, Sendable {
    public let segmentID: UUID
    public let meetingID: MeetingID
    public let text: String
    public let askedAt: TimeInterval

    public init(
        segmentID: UUID,
        meetingID: MeetingID,
        text: String,
        askedAt: TimeInterval
    ) {
        self.segmentID = segmentID
        self.meetingID = meetingID
        self.text = text
        self.askedAt = askedAt
    }
}

/// One exact closed transcript turn that may support an interview answer.
/// The raw channel and timestamp remain attached so presentation never has
/// to infer who supplied the evidence or invent a source location.
public struct InterviewEvidence: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let meetingID: MeetingID
    public let channel: AudioChannel
    public let timestamp: TimeInterval
    public let endedAt: TimeInterval
    public let text: String

    public init(
        id: UUID,
        meetingID: MeetingID,
        channel: AudioChannel,
        timestamp: TimeInterval,
        endedAt: TimeInterval,
        text: String
    ) {
        self.id = id
        self.meetingID = meetingID
        self.channel = channel
        self.timestamp = timestamp
        self.endedAt = endedAt
        self.text = text
    }
}

public struct InterviewQuestionContext: Equatable, Sendable {
    public let question: InterviewQuestion
    public let evidence: [InterviewEvidence]

    public init(
        question: InterviewQuestion,
        evidence: [InterviewEvidence]
    ) {
        self.question = question
        self.evidence = evidence
    }
}

/// Pure, bounded current-question and evidence policy. Interview Assist only
/// considers questions from the remote/room channels and only supplies exact
/// closed turns that precede that question. An old question expires instead
/// of remaining "current" forever during a long answer or a new topic.
public enum InterviewQuestionPolicy {
    public static let maximumCandidateRows = 24
    public static let maximumEvidenceRows = 8
    public static let maximumQuestionCharacters = 600
    public static let maximumQuestionUTF8Bytes = 4_800
    public static let maximumEvidenceCharacters = 2_000
    public static let maximumEvidenceUTF8Bytes = 12_000
    public static let currentQuestionLifetime: TimeInterval = 180

    public static func context(
        in captions: [TranscriptSegment]
    ) -> InterviewQuestionContext? {
        let lowerBound = max(0, captions.count - maximumCandidateRows)
        let candidateIndexes = captions.indices[lowerBound...]
        let newestEnd = candidateIndexes
            .map { captions[$0].endTime }
            .filter(\.isFinite)
            .max()
        guard let newestEnd,
              let questionIndex = candidateIndexes
                .filter({ isQuestionCandidate(
                    captions[$0],
                    newestEnd: newestEnd) })
                .max(by: { lhs, rhs in
                    let left = captions[lhs]
                    let right = captions[rhs]
                    return left.startTime == right.startTime
                        ? lhs < rhs
                        : left.startTime < right.startTime
                })
        else { return nil }

        let row = captions[questionIndex]
        let question = InterviewQuestion(
            segmentID: row.id,
            meetingID: row.meetingID,
            text: row.text.trimmingCharacters(in: .whitespacesAndNewlines),
            askedAt: row.startTime)
        let evidence = captions.suffix(maximumCandidateRows)
            .enumerated()
            .compactMap { offset, candidate -> (Int, InterviewEvidence)? in
                guard candidate.id != row.id,
                      candidate.meetingID == row.meetingID,
                      candidate.endTime <= row.startTime,
                      let evidence = Self.evidence(from: candidate)
                else { return nil }
                return (offset, evidence)
            }
            .sorted { lhs, rhs in
                if lhs.1.timestamp != rhs.1.timestamp {
                    return lhs.1.timestamp < rhs.1.timestamp
                }
                if lhs.1.endedAt != rhs.1.endedAt {
                    return lhs.1.endedAt < rhs.1.endedAt
                }
                return lhs.0 < rhs.0
            }
            .suffix(maximumEvidenceRows)
            .map(\.1)
        return InterviewQuestionContext(
            question: question,
            evidence: Array(evidence))
    }

    private static func isQuestionCandidate(
        _ row: TranscriptSegment,
        newestEnd: TimeInterval
    ) -> Bool {
        guard row.channel == .system || row.channel == .room,
              row.isFinal,
              row.startTime.isFinite,
              row.endTime.isFinite,
              row.startTime <= row.endTime,
              newestEnd - row.endTime <= currentQuestionLifetime
        else { return false }
        let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              text.count <= maximumQuestionCharacters,
              text.utf8.count <= maximumQuestionUTF8Bytes
        else { return false }
        return QuestionHeuristic.looksLikeQuestion(text)
    }

    private static func evidence(
        from row: TranscriptSegment
    ) -> InterviewEvidence? {
        let text = row.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row.isFinal,
              row.startTime.isFinite,
              row.endTime.isFinite,
              row.startTime <= row.endTime,
              !text.isEmpty,
              text.count <= maximumEvidenceCharacters,
              text.utf8.count <= maximumEvidenceUTF8Bytes
        else { return nil }
        return InterviewEvidence(
            id: row.id,
            meetingID: row.meetingID,
            channel: row.channel,
            timestamp: row.startTime,
            endedAt: row.endTime,
            text: text)
    }
}

public protocol InterviewQuestionAnswering: Sendable {
    /// Returns the provider's raw citation-bearing answer. nil means the
    /// explicitly selected engine is unavailable; it must not silently fall
    /// through to another provider.
    func answer(
        question: String,
        passages: [RAGPassage]
    ) async throws -> String?
}

public struct InterviewAnswerCitation: Equatable, Sendable, Identifiable {
    public var id: UUID { evidence.id }
    public let number: Int
    public let evidence: InterviewEvidence

    public init(number: Int, evidence: InterviewEvidence) {
        self.number = number
        self.evidence = evidence
    }
}

public struct InterviewGroundedAnswer: Equatable, Sendable {
    public let text: String
    public let citations: [InterviewAnswerCitation]

    public init(text: String, citations: [InterviewAnswerCitation]) {
        self.text = text
        self.citations = citations
    }
}

public enum InterviewAssistanceResponse: Equatable, Sendable {
    case answered(InterviewGroundedAnswer)
    case insufficientEvidence
    case unavailable
    case failed
    case timedOut
}

private enum InterviewAnswerValidation {
    static let maximumAnswerCharacters = 2_000
    static let maximumAnswerUTF8Bytes = 16_000

    static func admit(
        _ raw: String,
        evidence: [InterviewEvidence]
    ) -> InterviewGroundedAnswer? {
        guard !evidence.isEmpty,
              raw.count <= maximumAnswerCharacters,
              raw.utf8.count <= maximumAnswerUTF8Bytes,
              let indexes = NumberedCitationAnswer.exactIndexes(
                in: raw,
                evidenceCount: evidence.count),
              let text = CompanionAnswer.usable(raw)
        else { return nil }
        return InterviewGroundedAnswer(
            text: text,
            citations: indexes.map {
                InterviewAnswerCitation(number: $0 + 1, evidence: evidence[$0])
            })
    }

}

/// One pull-based interview answer request. Evidence is preserved even when
/// the chosen engine is missing, fails, or times out, but unsupported model
/// prose is never published as an answer.
public struct AssistInterviewQuestion: ApplicationUseCase {
    private let answering: any InterviewQuestionAnswering
    private let timeout: Duration

    public init(
        answering: any InterviewQuestionAnswering,
        timeout: Duration = .seconds(8)
    ) {
        self.answering = answering
        self.timeout = timeout > .zero ? timeout : .seconds(8)
    }

    public func execute(
        _ context: InterviewQuestionContext
    ) async throws -> InterviewAssistanceResponse {
        guard !context.evidence.isEmpty else { return .insufficientEvidence }
        guard Self.isValid(context) else { return .insufficientEvidence }
        let passages = context.evidence.map(Self.passage)
        do {
            let raw = try await withAskTimeout(
                timeout,
                onTimeout: {},
                operation: {
                    try await answering.answer(
                        question: context.question.text,
                        passages: passages)
                })
            try Task.checkCancellation()
            guard let raw else { return .unavailable }
            guard let answer = InterviewAnswerValidation.admit(
                raw,
                evidence: context.evidence)
            else { return .insufficientEvidence }
            return .answered(answer)
        } catch is CancellationError {
            throw CancellationError()
        } catch is AskTimeoutError {
            return .timedOut
        } catch {
            return .failed
        }
    }

    private static func isValid(_ context: InterviewQuestionContext) -> Bool {
        let question = context.question
        let trimmedQuestion = question.text.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard question.askedAt.isFinite,
              !trimmedQuestion.isEmpty,
              trimmedQuestion == question.text,
              question.text.count <= InterviewQuestionPolicy.maximumQuestionCharacters,
              question.text.utf8.count <= InterviewQuestionPolicy.maximumQuestionUTF8Bytes,
              context.evidence.count <= InterviewQuestionPolicy.maximumEvidenceRows
        else { return false }
        var seen: Set<UUID> = []
        let evidenceIsValid = context.evidence.allSatisfy { item in
            let trimmedEvidence = item.text.trimmingCharacters(
                in: .whitespacesAndNewlines)
            return item.id != question.segmentID
                && item.meetingID == question.meetingID
                && seen.insert(item.id).inserted
                && item.timestamp.isFinite
                && item.endedAt.isFinite
                && item.timestamp <= item.endedAt
                && item.endedAt <= question.askedAt
                && !trimmedEvidence.isEmpty
                && trimmedEvidence == item.text
                && item.text.count <= InterviewQuestionPolicy.maximumEvidenceCharacters
                && item.text.utf8.count
                    <= InterviewQuestionPolicy.maximumEvidenceUTF8Bytes
        }
        guard evidenceIsValid else { return false }
        return zip(context.evidence, context.evidence.dropFirst()).allSatisfy { earlier, later in
            earlier.timestamp < later.timestamp
                || (earlier.timestamp == later.timestamp
                    && earlier.endedAt <= later.endedAt)
        }
    }

    private static func passage(_ evidence: InterviewEvidence) -> RAGPassage {
        RAGPassage(
            segmentID: evidence.id,
            meetingID: evidence.meetingID,
            meetingTitle: "This interview",
            timestamp: evidence.timestamp,
            text: (evidence.channel == .microphone ? "Me: " : "Them: ")
                + evidence.text)
    }
}
