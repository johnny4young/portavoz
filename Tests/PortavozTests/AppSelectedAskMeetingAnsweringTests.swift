import ApplicationKit
import Foundation
import IntelligenceKit
import PortavozCore
@testable import portavoz_app
import XCTest

@MainActor
final class AppSelectedAskMeetingAnsweringTests: XCTestCase {
    func testUninstalledOrUnavailableResolverPreservesEvidenceOnlyAnswer() async throws {
        let router = AppSelectedAskMeetingAnswering()
        let citation = fixtureCitation()

        let beforeInstall = try await router.answer(
            question: "What changed?",
            citations: [citation])
        XCTAssertNil(beforeInstall)

        router.install { .unavailable(.requiresMacOS26) }
        let unavailable = try await router.answer(
            question: "What changed?",
            citations: [citation])
        XCTAssertNil(unavailable)
    }

    func testResolverInstallationIsSingleAssignmentWithoutCrashing() async throws {
        let router = AppSelectedAskMeetingAnswering()
        XCTAssertTrue(router.install {
            .available(CapturingRAGProvider(answer: "First [1]."))
        })
        XCTAssertFalse(router.install {
            .available(CapturingRAGProvider(answer: "Unexpected [1]."))
        })

        let answer = try await router.answer(
            question: "What changed?",
            citations: [fixtureCitation()])
        XCTAssertEqual(answer, "First [1].")
    }

    func testRouterSamplesProviderPerRequestAndPreservesExactPassage() async throws {
        let first = CapturingRAGProvider(answer: "First [1].")
        let second = CapturingRAGProvider(answer: "Second [1].")
        let selections = AskProviderSelectionProbe(providers: [first, second])
        let router = AppSelectedAskMeetingAnswering()
        router.install { selections.next() }
        let citation = fixtureCitation()
        let snapshots = AskRouterSnapshotProbe()

        let firstAnswer = try await router.answer(
            question: "What changed?",
            citations: [citation],
            onAnswer: { update in await snapshots.record(update.text) })
        let secondAnswer = try await router.answer(
            question: "What changed next?",
            citations: [citation])
        let publishedSnapshots = await snapshots.snapshot()
        let firstCapture = await first.snapshot()

        XCTAssertEqual(firstAnswer, "First [1].")
        XCTAssertEqual(secondAnswer, "Second [1].")
        XCTAssertEqual(publishedSnapshots, ["First [1]."])
        XCTAssertEqual(selections.requestCount, 2)
        let captured = try XCTUnwrap(firstCapture)
        XCTAssertEqual(captured.question, "What changed?")
        XCTAssertEqual(captured.passages.count, 1)
        XCTAssertEqual(captured.passages[0].segmentID, citation.segmentID)
        XCTAssertEqual(captured.passages[0].sourceSegmentIDs, citation.sourceSegmentIDs)
        XCTAssertEqual(captured.passages[0].meetingID, citation.meetingID)
        XCTAssertEqual(captured.passages[0].transcriptRevision, citation.transcriptRevision)
        XCTAssertEqual(captured.passages[0].text, citation.text)
    }

    private func fixtureCitation() -> AskCitation {
        let segmentID = UUID()
        return AskCitation(
            segmentID: segmentID,
            sourceSegmentIDs: [segmentID],
            meetingID: MeetingID(),
            meetingTitle: "Planning",
            timestamp: 3,
            transcriptRevision: 4,
            text: "The rollout remains Friday.")
    }
}

@MainActor
private final class AskProviderSelectionProbe {
    private var providers: [any RAGTextAnswering]
    private(set) var requestCount = 0

    init(providers: [any RAGTextAnswering]) {
        self.providers = providers
    }

    func next() -> AppAskAnswerProviderResolution {
        defer { requestCount += 1 }
        return .available(providers[min(requestCount, providers.count - 1)])
    }
}

private actor CapturingRAGProvider: RAGTextAnswering {
    struct Request: Sendable {
        let question: String
        let passages: [RAGPassage]
    }

    let answer: String
    private var request: Request?

    init(answer: String) {
        self.answer = answer
    }

    func answer(
        question: String,
        passages: [RAGPassage]
    ) async throws -> String {
        request = Request(question: question, passages: passages)
        return answer
    }

    func snapshot() -> Request? { request }
}

private actor AskRouterSnapshotProbe {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}
