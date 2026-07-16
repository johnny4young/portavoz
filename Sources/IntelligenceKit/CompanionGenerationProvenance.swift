import Foundation
import PortavozCore

public enum CompanionGenerationWorkflow: String, Sendable {
    case liveRecording = "live-recording"
    case postRefine = "post-refine"
}

public struct CompanionExternalProviderIdentity: Equatable, Sendable {
    public let providerID: String
    public let modelID: String
    public let destinationIdentity: String

    public init(
        providerID: String,
        modelID: String,
        destinationIdentity: String? = nil
    ) {
        self.providerID = providerID
        self.modelID = modelID
        self.destinationIdentity = destinationIdentity ?? providerID
    }
}

public struct CompanionGenerationRequest: Sendable {
    public let meetingID: MeetingID
    public let sourceTranscriptRevision: Int
    public let workflow: CompanionGenerationWorkflow
    public let candidate: String
    public let recentTranscript: [RAGPassage]
    public let ownerName: String?
    public let outputLanguage: String?
    public let askedAt: TimeInterval

    public init(
        meetingID: MeetingID,
        sourceTranscriptRevision: Int,
        workflow: CompanionGenerationWorkflow,
        candidate: String,
        recentTranscript: [RAGPassage],
        ownerName: String?,
        outputLanguage: String?,
        askedAt: TimeInterval
    ) {
        self.meetingID = meetingID
        self.sourceTranscriptRevision = sourceTranscriptRevision
        self.workflow = workflow
        self.candidate = candidate
        self.recentTranscript = recentTranscript
        self.ownerName = ownerName
        self.outputLanguage = outputLanguage
        self.askedAt = askedAt
    }
}

public enum CompanionGenerationResult: Sendable {
    case noAttempt
    case noArtifact
    case unavailable
    case artifact(CompanionGenerationArtifact)
    case terminal(GenerationRun)
}

public enum CompanionGenerationOperationFingerprint {
    private static let version = "companion-generation-v1"

    public static func compute(
        request: CompanionGenerationRequest,
        externalProvider: CompanionExternalProviderIdentity?
    ) -> String? {
        guard request.sourceTranscriptRevision >= 0,
              !request.candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              externalProvider.map(Self.isValid) ?? true
        else { return nil }

        let components = [
            request.meetingID.rawValue.uuidString,
            String(request.sourceTranscriptRevision),
            request.workflow.rawValue,
            request.candidate,
            optional("owner", request.ownerName),
            optional("language", request.outputLanguage),
            String(request.askedAt.bitPattern, radix: 16),
            optional("external-destination", externalProvider?.destinationIdentity),
            optional("external-provider", externalProvider?.providerID),
            optional("external-model", externalProvider?.modelID),
            String(request.recentTranscript.count)
        ] + request.recentTranscript.flatMap { passage in
            [
                passage.meetingID.rawValue.uuidString,
                passage.meetingTitle,
                String(passage.timestamp.bitPattern, radix: 16),
                passage.text
            ]
        }
        return OperationFingerprint.make(version: version, components: components)
    }

    private static func optional(_ label: String, _ value: String?) -> String {
        guard let value else { return "\(label):none" }
        return "\(label):some:\(value)"
    }

    private static func isValid(_ provider: CompanionExternalProviderIdentity) -> Bool {
        [provider.destinationIdentity, provider.providerID, provider.modelID].allSatisfy {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

public struct CompanionGenerationAttempt: Sendable {
    public static let foundationProviderID = "foundation-models"
    public static let foundationModelID = "system-language-model"

    private let id: GenerationRunID
    private let request: CompanionGenerationRequest
    private let inputFingerprint: String
    private let externalProvider: CompanionExternalProviderIdentity?
    private let startedAt: Date

    public init?(
        id: GenerationRunID = GenerationRunID(),
        request: CompanionGenerationRequest,
        externalProvider: CompanionExternalProviderIdentity?,
        startedAt: Date
    ) {
        guard let inputFingerprint = CompanionGenerationOperationFingerprint.compute(
            request: request,
            externalProvider: externalProvider)
        else { return nil }
        self.id = id
        self.request = request
        self.inputFingerprint = inputFingerprint
        self.externalProvider = externalProvider
        self.startedAt = startedAt
    }

    public func finish(
        outcome: GenerationRunOutcome,
        trace: CompanionProcessTrace,
        card: CompanionCard?,
        at finishedAt: Date
    ) -> GenerationRun {
        let providerID = trace.answerProviderID ?? Self.foundationProviderID
        let modelID = trace.answerModelID ?? Self.foundationModelID
        return GenerationRun(
            id: id,
            meetingID: request.meetingID,
            kind: .companion,
            providerID: providerID,
            modelID: modelID,
            inputFingerprint: inputFingerprint,
            configJSON: Self.json(Configuration(
                answerModelID: trace.answerModelID,
                answerProviderID: trace.answerProviderID,
                classifierModelID: Self.foundationModelID,
                classifierProviderID: Self.foundationProviderID,
                classifierInvoked: trace.classifierInvoked,
                contextPassageCount: request.recentTranscript.count,
                externalModelID: externalProvider?.modelID,
                externalProviderID: externalProvider?.providerID,
                externalProviderConfigured: externalProvider != nil,
                externalTransferOccurred: trace.externalTransferOccurred,
                externalTransferSucceeded: trace.externalTransferSucceeded,
                operation: "classify-and-answer",
                sourceTranscriptRevision: request.sourceTranscriptRevision,
                workflow: request.workflow.rawValue)),
            outputLanguage: request.outputLanguage,
            startedAt: startedAt,
            finishedAt: finishedAt,
            outcome: outcome,
            metricsJSON: card.map {
                Self.json(Metrics(
                    answerUTF8Bytes: $0.answer.utf8.count,
                    directed: $0.directed,
                    kind: $0.kind.rawValue,
                    questionUTF8Bytes: $0.question.utf8.count))
            })
    }

    private static func json<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let text = String(data: data, encoding: .utf8)
        else { return "{}" }
        return text
    }

    private struct Configuration: Encodable {
        let answerModelID: String?
        let answerProviderID: String?
        let classifierModelID: String
        let classifierProviderID: String
        let classifierInvoked: Bool
        let contextPassageCount: Int
        let externalModelID: String?
        let externalProviderID: String?
        let externalProviderConfigured: Bool
        let externalTransferOccurred: Bool
        let externalTransferSucceeded: Bool
        let operation: String
        let sourceTranscriptRevision: Int
        let workflow: String
    }

    private struct Metrics: Encodable {
        let answerUTF8Bytes: Int
        let directed: Bool
        let kind: String
        let questionUTF8Bytes: Int
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, iOS 26.0, *)
public struct ProvenanceCompanion: Sendable {
    private let companion: LiveCompanion
    private let externalProvider: CompanionExternalProviderIdentity?
    private let makeGenerationRunID: @Sendable () -> GenerationRunID
    private let now: @Sendable () -> Date

    public init(
        byok: OpenAICompatibleChatClient? = nil,
        makeGenerationRunID: @escaping @Sendable () -> GenerationRunID = {
            GenerationRunID()
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        companion = LiveCompanion(byok: byok)
        externalProvider = byok.map {
            CompanionExternalProviderIdentity(
                providerID: $0.providerLabel,
                modelID: $0.model,
                destinationIdentity: $0.endpoint.absoluteString)
        }
        self.makeGenerationRunID = makeGenerationRunID
        self.now = now
    }

    public func generate(_ request: CompanionGenerationRequest) async -> CompanionGenerationResult {
        let mentioned = request.ownerName.map {
            QuestionHeuristic.mentions($0, in: request.candidate)
        } ?? false
        guard QuestionHeuristic.looksLikeQuestion(request.candidate) || mentioned else {
            return .noAttempt
        }
        guard FoundationModelSummaryProvider.unavailabilityReason() == nil else {
            return .unavailable
        }
        guard let attempt = CompanionGenerationAttempt(
            id: makeGenerationRunID(),
            request: request,
            externalProvider: externalProvider,
            startedAt: now())
        else { return .unavailable }

        do {
            let result = try await companion.processWithTrace(
                candidate: request.candidate,
                recentTranscript: request.recentTranscript,
                ownerName: request.ownerName,
                askedAt: request.askedAt)
            guard let card = result.card else { return .noArtifact }
            let run = attempt.finish(
                outcome: .succeeded,
                trace: result.trace,
                card: card,
                at: now())
            return .artifact(CompanionGenerationArtifact(card: card, generationRun: run))
        } catch let failure as CompanionProcessFailure {
            return .terminal(attempt.finish(
                outcome: failure.cancelled ? .cancelled : .failed,
                trace: failure.trace,
                card: nil,
                at: now()))
        } catch {
            return .terminal(attempt.finish(
                outcome: error is CancellationError ? .cancelled : .failed,
                trace: CompanionProcessTrace(),
                card: nil,
                at: now()))
        }
    }
}
#endif
