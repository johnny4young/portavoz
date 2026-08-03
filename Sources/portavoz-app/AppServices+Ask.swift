import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

@MainActor
final class AppAskModelClient: AskModelClient {
    private let useCase: AskMeetings

    init(useCase: AskMeetings) {
        self.useCase = useCase
    }

    func searchAskMeetings(
        _ query: String,
        limit: Int
    ) async throws -> [AskSearchResult] {
        try await useCase.search(query, limit: limit)
    }

    func answerAskMeetings(
        _ question: String,
        limit: Int
    ) async throws -> AskMeetingAnswer {
        try await useCase.answer(question, limit: limit)
    }

    func answerAskMeetings(
        _ question: String,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        try await useCase.answer(
            question,
            limit: limit,
            onEvidence: onEvidence)
    }
}

struct AppSemanticSearchComposition {
    let coordinator: SemanticCorpusIndexingCoordinator
    let ask: AskMeetings
    let library: LocalLibrarySemanticSearch
    let background: SemanticCorpusIndexingSupervisor
    let memoryGraphBackground: MeetingMemoryGraphProjectionSupervisor
}

extension AppServices {
    func makeAskModel() -> AskModel {
        AskModel(client: askClient)
    }

    static func makeSemanticSearchComposition(
        store: MeetingStore,
        usesTemporaryStore: Bool,
        semanticRuntime: any SemanticEmbeddingRuntimeClient,
        telemetry: ResourceWorkloadTelemetry,
        pipelineTelemetry: AskPipelineTelemetry = AppAskPipelineTelemetry.shared.telemetry,
        captureState: AppResourceCaptureState
    ) -> AppSemanticSearchComposition {
        let maintenanceGate = AppResourceGovernorMaintenanceGate.make(
            captureState: captureState)
        let coordinator = SemanticCorpusIndexingCoordinator(
            operation: IndexSemanticCorpus(
                store: store,
                telemetry: telemetry,
                maintenanceGate: maintenanceGate))
        let maintenanceState = SemanticCorpusMaintenanceState()
        let readiness = ResolveSemanticCorpusReadiness(
            store: store,
            runtime: semanticRuntime,
            maintenanceState: maintenanceState)
        let ask: AskMeetings
        if usesTemporaryStore {
            ask = AskMeetings(
                retrieval: UITestAskMeetingRetrieval(store: store),
                answering: UITestAskMeetingAnswering())
        } else {
            ask = .local(
                store: store,
                semanticRuntime: semanticRuntime,
                semanticReadiness: readiness,
                pipelineTelemetry: pipelineTelemetry)
        }
        let library = LocalLibrarySemanticSearch(
            store: store,
            runtime: semanticRuntime,
            semanticReadiness: readiness)
        let backgroundIndexer = AppSemanticCorpusBackgroundIndexer(
            store: store,
            runtime: semanticRuntime,
            coordinator: coordinator,
            captureState: captureState)
        let background = SemanticCorpusIndexingSupervisor(
            isEnabled: !usesTemporaryStore,
            maintenanceState: maintenanceState,
            drain: backgroundIndexer.drain(owner:))
        let graphProjector = AppMeetingMemoryGraphBackgroundProjector(
            store: store,
            projector: ProjectMeetingMemoryGraph(
                store: store,
                telemetry: telemetry,
                maintenanceGate: maintenanceGate),
            captureState: captureState)
        let memoryGraphBackground = MeetingMemoryGraphProjectionSupervisor(
            isEnabled: !usesTemporaryStore,
            drain: graphProjector.drain(owner:))
        return AppSemanticSearchComposition(
            coordinator: coordinator,
            ask: ask,
            library: library,
            background: background,
            memoryGraphBackground: memoryGraphBackground)
    }
}

/// Disposable UI-test adapter: exercises the real temporary FTS library while
/// avoiding model downloads. Production composition never selects it.
private struct UITestAskMeetingRetrieval: AskMeetingRetrieving {
    let store: MeetingStore

    func search(query: String, limit: Int) async throws -> [AskSearchResult] {
        try await store.search(query, limit: limit).map(Self.searchResult)
    }

    func retrieve(question: String, limit: Int) async throws -> [AskCitation] {
        try await store.search(
            question,
            limit: limit,
            requireAll: false
        ).map { hit in
            AskCitation(
                segmentID: hit.segmentID,
                meetingID: hit.meetingID,
                meetingTitle: hit.meetingTitle,
                timestamp: hit.startTime,
                transcriptRevision: hit.transcriptRevision,
                text: hit.text)
        }
    }

    func retrieve(
        question: String,
        limit: Int,
        trace _: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        let citations = try await retrieve(question: question, limit: limit)
        await onEvidence(AskEvidenceUpdate(
            phase: .lexical,
            citations: citations))
        try await Task.sleep(for: .seconds(5))
        await onEvidence(AskEvidenceUpdate(
            phase: .fused,
            citations: citations))
        return citations
    }

    private static func searchResult(_ hit: SearchHit) -> AskSearchResult {
        AskSearchResult(
            meetingID: hit.meetingID,
            meetingTitle: hit.meetingTitle,
            segmentID: hit.segmentID,
            snippet: hit.snippet,
            timestamp: hit.startTime)
    }
}

private struct UITestAskMeetingAnswering: AskMeetingAnswering {
    func answer(
        question _: String,
        citations _: [AskCitation]
    ) async throws -> String? {
        try await Task.sleep(for: .seconds(5))
        return "El presupuesto se revisó y el rollout quedó para el viernes."
    }
}
