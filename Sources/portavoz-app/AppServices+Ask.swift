import ApplicationKit
import Foundation
import IntegrationsKit
import PortavozCore
import StorageKit

@MainActor
final class AppAskModelClient: AskModelClient {
    private let useCase: AskMeetings
    private let webUseCase: AskWeb
    private let memoryEntities: LoadAutomationEntities
    private let memoryCommitments: LoadPersonCommitments
    private let memoryCommitmentBlockers: LoadCommitmentBlockers
    private let memoryTopics: LoadConfirmedTopicCatalog
    private let memoryDecisionHistory: LoadDecisionHistory
    private let memoryTopicFirstDiscussion: LoadTopicFirstDiscussion
    private let memoryDecisionConflicts: LoadDecisionConflicts
    private let memoryChangesSince: LoadChangeSince

    init(
        useCase: AskMeetings,
        webUseCase: AskWeb,
        store: MeetingStore,
        graphTelemetry: MeetingMemoryGraphQueryTelemetry =
            AppMeetingMemoryGraphQueryTelemetry.shared.telemetry
    ) {
        self.useCase = useCase
        self.webUseCase = webUseCase
        memoryEntities = LoadAutomationEntities(catalog: store)
        memoryCommitments = LoadPersonCommitments(
            repository: store,
            telemetry: graphTelemetry)
        memoryCommitmentBlockers = LoadCommitmentBlockers(
            repository: store,
            telemetry: graphTelemetry)
        memoryTopics = LoadConfirmedTopicCatalog(catalog: store)
        memoryDecisionHistory = LoadDecisionHistory(
            repository: store,
            telemetry: graphTelemetry)
        memoryTopicFirstDiscussion = LoadTopicFirstDiscussion(
            repository: store,
            telemetry: graphTelemetry)
        memoryDecisionConflicts = LoadDecisionConflicts(
            repository: store,
            telemetry: graphTelemetry)
        memoryChangesSince = LoadChangeSince(
            repository: store,
            telemetry: graphTelemetry)
    }

    func searchAskMeetings(
        _ query: String,
        source: AskSourceScope,
        limit: Int
    ) async throws -> [AskSearchResult] {
        try await useCase.search(query, source: source, limit: limit)
    }

    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int
    ) async throws -> AskMeetingAnswer {
        try await useCase.answer(question, source: source, limit: limit)
    }

    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> AskMeetingAnswer {
        try await useCase.answer(
            question,
            source: source,
            limit: limit,
            onEvidence: onEvidence)
    }

    func answerAskMeetings(
        _ question: String,
        source: AskSourceScope,
        limit: Int,
        onEvidence: @escaping AskEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskMeetingAnswer {
        try await useCase.answer(
            question,
            source: source,
            limit: limit,
            onEvidence: onEvidence,
            onAnswer: onAnswer)
    }

    func loadAskSourceMeetings(
        limit: Int
    ) async throws -> [AskSourceMeetingOption] {
        try await memoryEntities.meetings(AutomationEntityLookup(limit: limit))
            .map {
                AskSourceMeetingOption(
                    id: $0.id,
                    title: $0.title,
                    startedAt: $0.startedAt)
            }
    }

    func answerAskWeb(
        _ request: AskWebRequest,
        onEvidence: @escaping AskWebEvidenceReceiver,
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> AskWebAnswer {
        try await webUseCase.answer(
            request,
            onEvidence: onEvidence,
            onAnswer: onAnswer)
    }
}

extension AppAskModelClient: AskMemoryModelClient {
    func searchAskMemoryPeople(
        _ query: String,
        limit: Int
    ) async throws -> [Person] {
        try await memoryEntities.people(AutomationEntityLookup(
            matching: query,
            limit: limit))
    }

    func loadAskMemoryPersonCommitments(
        personID: PersonID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await memoryCommitments.execute(PersonCommitmentsQuery(
            personID: personID,
            itemLimit: limit))
    }

    func loadAskMemoryCommitmentBlockers(
        commitmentID: CommitmentID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await memoryCommitmentBlockers.execute(CommitmentBlockerQuery(
            commitmentID: commitmentID,
            itemLimit: limit))
    }

    func searchAskMemoryTopics(
        _ query: String,
        limit: Int
    ) async throws -> [Topic] {
        try await memoryTopics.execute(ConfirmedTopicCatalogLookup(
            matching: query,
            limit: limit))
    }

    func searchAskMemoryMeetingAnchors(
        _ query: String,
        limit: Int
    ) async throws -> [Meeting] {
        try await memoryEntities.meetings(AutomationEntityLookup(
            matching: query,
            limit: limit))
    }

    func loadAskMemoryDecisionHistory(
        topicID: TopicID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await memoryDecisionHistory.execute(DecisionHistoryQuery(
            topicID: topicID,
            itemLimit: limit))
    }

    func loadAskMemoryTopicFirstDiscussion(
        topicID: TopicID
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await memoryTopicFirstDiscussion.execute(TopicFirstDiscussionQuery(
            topicID: topicID))
    }

    func loadAskMemoryDecisionConflicts(
        topicID: TopicID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await memoryDecisionConflicts.execute(DecisionConflictsQuery(
            topicID: topicID,
            itemLimit: limit))
    }

    func loadAskMemoryChangesSince(
        topicID: TopicID,
        sinceMeetingID: MeetingID,
        limit: Int
    ) async throws -> MeetingMemoryGraphQueryResult {
        try await memoryChangesSince.execute(ChangeSinceQuery(
            topicID: topicID,
            sinceMeetingID: sinceMeetingID,
            itemLimit: limit))
    }
}

struct AppSemanticSearchComposition {
    let coordinator: SemanticCorpusIndexingCoordinator
    let ask: AskMeetings
    let webAsk: AskWeb
    let library: LocalLibrarySemanticSearch
    let background: SemanticCorpusIndexingSupervisor
    let memoryGraphBackground: MeetingMemoryGraphProjectionSupervisor
}

extension AppServices {
    func makeAskModel() -> AskModel {
        AskModel(
            client: askClient,
            memoryClient: askClient,
            webSourcePolicy: usesTemporaryMeetingStore
                ? .loopbackFixture
                : .publicHTTPS)
    }

    static func makeSemanticSearchComposition(
        store: MeetingStore,
        usesTemporaryStore: Bool,
        semanticRuntime: any SemanticEmbeddingRuntimeClient,
        selectedAnswering: any AskMeetingAnswering & AskWebAnswering,
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
        let (ask, webAnswering) = makeAskUseCases(
            store: store,
            usesTemporaryStore: usesTemporaryStore,
            semanticRuntime: semanticRuntime,
            readiness: readiness,
            pipelineTelemetry: pipelineTelemetry,
            selectedAnswering: selectedAnswering)
        let webAsk = makeWebAsk(
            store: store,
            usesTemporaryStore: usesTemporaryStore,
            answering: webAnswering)
        let library = LocalLibrarySemanticSearch(
            store: store,
            runtime: semanticRuntime,
            semanticReadiness: readiness)
        let background = makeSemanticBackground(
            store: store,
            usesTemporaryStore: usesTemporaryStore,
            runtime: semanticRuntime,
            coordinator: coordinator,
            maintenanceState: maintenanceState,
            captureState: captureState)
        let memoryGraphBackground = makeMemoryGraphBackground(
            store: store,
            usesTemporaryStore: usesTemporaryStore,
            telemetry: telemetry,
            maintenanceGate: maintenanceGate,
            captureState: captureState)
        return AppSemanticSearchComposition(
            coordinator: coordinator,
            ask: ask,
            webAsk: webAsk,
            library: library,
            background: background,
            memoryGraphBackground: memoryGraphBackground)
    }

    private static func makeAskUseCases(
        store: MeetingStore,
        usesTemporaryStore: Bool,
        semanticRuntime: any SemanticEmbeddingRuntimeClient,
        readiness: ResolveSemanticCorpusReadiness,
        pipelineTelemetry: AskPipelineTelemetry,
        selectedAnswering: any AskMeetingAnswering & AskWebAnswering
    ) -> (AskMeetings, any AskWebAnswering) {
        if usesTemporaryStore {
            return (
                AskMeetings(
                    retrieval: UITestAskMeetingRetrieval(store: store),
                    answering: UITestAskMeetingAnswering()),
                UITestAskWebAnswering())
        }
        return (
            .local(
                store: store,
                semanticRuntime: semanticRuntime,
                semanticReadiness: readiness,
                pipelineTelemetry: pipelineTelemetry,
                answering: selectedAnswering),
            selectedAnswering)
    }

    private static func makeWebAsk(
        store: MeetingStore,
        usesTemporaryStore: Bool,
        answering: any AskWebAnswering
    ) -> AskWeb {
        AskWeb(
            retrieval: URLSessionAskWebSourceRetrieval(
                gateway: URLSessionDataEgressGateway(
                    session: makeAskWebSession(),
                    receiptRecorder: store),
                policy: usesTemporaryStore
                    ? .loopbackFixture
                    : .publicHTTPS),
            answering: answering)
    }

    private static func makeSemanticBackground(
        store: MeetingStore,
        usesTemporaryStore: Bool,
        runtime: any SemanticEmbeddingRuntimeClient,
        coordinator: SemanticCorpusIndexingCoordinator,
        maintenanceState: SemanticCorpusMaintenanceState,
        captureState: AppResourceCaptureState
    ) -> SemanticCorpusIndexingSupervisor {
        let indexer = AppSemanticCorpusBackgroundIndexer(
            store: store,
            runtime: runtime,
            coordinator: coordinator,
            captureState: captureState)
        return SemanticCorpusIndexingSupervisor(
            isEnabled: !usesTemporaryStore,
            maintenanceState: maintenanceState,
            drain: indexer.drain(owner:))
    }

    private static func makeMemoryGraphBackground(
        store: MeetingStore,
        usesTemporaryStore: Bool,
        telemetry: ResourceWorkloadTelemetry,
        maintenanceGate: DurableMaintenanceGate,
        captureState: AppResourceCaptureState
    ) -> MeetingMemoryGraphProjectionSupervisor {
        let projector = AppMeetingMemoryGraphBackgroundProjector(
            store: store,
            projector: ProjectMeetingMemoryGraph(
                store: store,
                telemetry: telemetry,
                maintenanceGate: maintenanceGate),
            captureState: captureState)
        return MeetingMemoryGraphProjectionSupervisor(
            isEnabled: !usesTemporaryStore,
            drain: projector.drain(owner:))
    }

    private static func makeAskWebSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = AskWeb.maximumSources
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
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
        try await Task.sleep(for: .milliseconds(500))
        await onEvidence(AskEvidenceUpdate(
            phase: .fused,
            citations: citations))
        return citations
    }

    func search(
        query: String,
        source: AskSourceScope,
        limit: Int,
        trace _: AskPipelineTrace
    ) async throws -> [AskSearchResult] {
        try await store.search(
            query,
            meetingID: try Self.meetingID(for: source),
            limit: limit)
            .map(Self.searchResult)
    }

    func retrieve(
        question: String,
        source: AskSourceScope,
        limit: Int,
        trace _: AskPipelineTrace,
        onEvidence: @escaping AskEvidenceReceiver
    ) async throws -> [AskCitation] {
        let citations = try await store.search(
            question,
            meetingID: try Self.meetingID(for: source),
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
        await onEvidence(AskEvidenceUpdate(
            phase: .lexical,
            citations: citations))
        try await Task.sleep(for: .milliseconds(500))
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

    private static func meetingID(
        for source: AskSourceScope
    ) throws -> MeetingID? {
        switch source {
        case .library:
            nil
        case .meeting(let meetingID):
            meetingID
        case .web:
            throw AskSourcePolicyError.webUnavailable
        }
    }
}

private struct UITestAskMeetingAnswering: AskMeetingAnswering {
    func answer(
        question _: String,
        citations _: [AskCitation]
    ) async throws -> String? {
        return "El presupuesto se revisó y el rollout quedó para el viernes."
    }

    func answer(
        question _: String,
        citations _: [AskCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        try await Task.sleep(for: .milliseconds(350))
        await onAnswer(AskAnswerUpdate(text: "El presupuesto se revisó"))
        try await Task.sleep(for: .milliseconds(350))
        let final = "El presupuesto se revisó y el rollout quedó para el viernes."
        await onAnswer(AskAnswerUpdate(text: final))
        return final
    }
}

private struct UITestAskWebAnswering: AskWebAnswering {
    func answer(
        question: String,
        citations _: [AskWebCitation]
    ) async throws -> String? {
        Self.answer(for: question)
    }

    func answer(
        question: String,
        citations _: [AskWebCitation],
        onAnswer: @escaping AskAnswerReceiver
    ) async throws -> String? {
        let answer = Self.answer(for: question)
        await onAnswer(AskAnswerUpdate(text: answer))
        return answer
    }

    private static func answer(for question: String) -> String {
        question.localizedCaseInsensitiveContains("Harbor")
            ? "Harbor launches September 14 at 09:00 UTC [1]."
            : "Costa se lanza el 18 de septiembre a las 10:00 UTC [1]."
    }
}
