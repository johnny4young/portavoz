import ApplicationKit
import Foundation
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
}

extension AppServices {
    func makeAskModel() -> AskModel {
        AskModel(client: askClient)
    }

    static func makeAskUseCase(
        store: MeetingStore,
        usesTemporaryStore: Bool
    ) -> AskMeetings {
        guard usesTemporaryStore else { return .local(store: store) }
        return AskMeetings(
            retrieval: UITestAskMeetingRetrieval(store: store),
            answering: UITestAskMeetingAnswering())
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
                text: hit.text)
        }
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
        "El presupuesto se revisó y el rollout quedó para el viernes."
    }
}
