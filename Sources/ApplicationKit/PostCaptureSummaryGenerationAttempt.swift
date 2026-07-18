import Foundation
import IntelligenceKit
import PortavozCore

/// Immutable metadata captured immediately before one durable summary attempt.
/// Its JSON payloads deliberately exclude meeting content.
public struct PostCaptureSummaryGenerationAttempt: Sendable {
    private let jobID: ProcessingJobID
    private let jobAttempt: Int
    private let meetingID: MeetingID
    private let providerID: String
    private let modelID: String
    private let modelRevision: String?
    private let inputFingerprint: String
    private let recipeID: String
    private let outputLanguage: String
    private let sourceTranscriptRevision: Int
    private let startedAt: Date

    public init(
        job: ProcessingJob,
        request: SummaryRequest,
        selection: PostCaptureSummaryProviderSelection,
        sourceTranscriptRevision: Int,
        startedAt: Date = Date()
    ) {
        jobID = job.id
        jobAttempt = job.attempt
        meetingID = job.meetingID
        providerID = selection.providerID
        modelID = selection.modelID
        modelRevision = selection.modelRevision
        inputFingerprint = job.inputFingerprint
        recipeID = request.recipe.id
        outputLanguage = request.targetLanguage
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.startedAt = startedAt
    }

    public func finish(
        outcome: GenerationRunOutcome,
        draft: SummaryDraft?,
        at finishedAt: Date = Date(),
        id: GenerationRunID = GenerationRunID()
    ) -> GenerationRun {
        GenerationRun(
            id: id,
            meetingID: meetingID,
            kind: .summary,
            providerID: providerID,
            modelID: modelID,
            modelRevision: modelRevision,
            inputFingerprint: inputFingerprint,
            configJSON: Self.json(Configuration(
                attempt: jobAttempt,
                jobID: jobID.rawValue.uuidString,
                operation: "generate",
                recipeID: recipeID,
                sourceTranscriptRevision: sourceTranscriptRevision,
                workflow: "post-capture")),
            outputLanguage: outputLanguage,
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            metricsJSON: draft.map {
                Self.json(Metrics(
                    actionItemCount: $0.actionItems.count,
                    outputUTF8Bytes: $0.markdown.utf8.count))
            })
    }

    private static func json<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    private struct Configuration: Encodable {
        let attempt: Int
        let jobID: String
        let operation: String
        let recipeID: String
        let sourceTranscriptRevision: Int
        let workflow: String
    }

    private struct Metrics: Encodable {
        let actionItemCount: Int
        let outputUTF8Bytes: Int
    }
}
