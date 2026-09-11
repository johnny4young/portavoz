import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore

extension AppServices {
    var regenerateCompanionCards: RegenerateCompanionCards {
        RegenerateCompanionCards(
            store: store,
            provider: AppCompanionRegenerationProvider(services: self))
    }
}

@MainActor
private final class AppCompanionRegenerationProvider: CompanionRegenerationProvider {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func regenerate(
        _ request: RegenerateCompanionCardsRequest
    ) async -> CompanionRegenerationProviderResult {
        guard let services else {
            return .pass(CompanionRegenerationPass(artifacts: [], completed: false))
        }
        if services.usesTemporaryMeetingStore,
           ProcessInfo.processInfo.arguments.contains(
               "-simulate-apuntador-refresh-success") {
            return fixturePass(for: request)
        }
        switch services.foundationModelsCapability {
        case .requiresMacOS26:
            return .unavailable(.requiresMacOS26)
        case .unavailable(let reason):
            return .unavailable(.appleOnDevice(reason: reason))
        case .available:
            break
        }
        guard #available(macOS 26.0, *) else {
            return .unavailable(.requiresMacOS26)
        }
        let refreshed = await CompanionRefresh.regenerate(
            from: request.material,
            meetingID: request.meetingID,
            workflow: .meetingReview,
            byok: await services.companionBYOKClient())
        return .pass(CompanionRegenerationPass(
            artifacts: refreshed.artifacts,
            terminalRuns: refreshed.terminalRuns,
            completed: refreshed.completed))
    }

    private func fixturePass(
        for request: RegenerateCompanionCardsRequest
    ) -> CompanionRegenerationProviderResult {
        let ordered = request.material.segments.sorted { $0.startTime < $1.startTime }
        guard let question = ordered.first(where: {
            $0.channel == .system && QuestionHeuristic.looksLikeQuestion($0.text)
        }),
        let answer = ordered.last(where: {
            $0.startTime < question.startTime && !$0.text.isEmpty
        })
        else {
            return .pass(CompanionRegenerationPass(artifacts: [], completed: false))
        }
        let generationRequest = CompanionGenerationRequest(
            meetingID: request.meetingID,
            sourceTranscriptRevision: request.material.baseTranscriptRevision,
            sourceCorrectionRevision: request.material.correctionRevision,
            workflow: .meetingReview,
            candidate: question.text,
            questionSegmentIDs: [question.id],
            recentTranscript: [RAGPassage(
                segmentID: answer.id,
                meetingID: request.meetingID,
                meetingTitle: "This meeting",
                timestamp: answer.startTime,
                text: answer.text)],
            evidenceSourceIDsByGeneratedID:
                request.material.sourceSegmentIDsByGeneratedID,
            ownerName: nil,
            outputLanguage: question.language,
            askedAt: question.startTime)
        guard let cardID = UUID(
            uuidString: "B5F00000-0000-4000-8000-000000000003"),
        let evidence = CompanionEvidenceFactory.make(
            cardID: cardID,
            request: generationRequest,
            answerEvidenceIndexes: [0]),
        let attempt = CompanionGenerationAttempt(
            request: generationRequest,
            externalProvider: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_200))
        else {
            return .pass(CompanionRegenerationPass(artifacts: [], completed: false))
        }
        let card = CompanionCard(
            id: cardID,
            question: question.text,
            answer: answer.text,
            kind: .context,
            source: "on-device",
            askedAt: question.startTime,
            evidence: evidence)
        let run = attempt.finish(
            outcome: .succeeded,
            trace: CompanionProcessTrace(classifierInvoked: true),
            card: card,
            at: Date(timeIntervalSince1970: 1_700_000_201))
        return .pass(CompanionRegenerationPass(
            artifacts: [CompanionGenerationArtifact(card: card, generationRun: run)],
            completed: true))
    }
}
