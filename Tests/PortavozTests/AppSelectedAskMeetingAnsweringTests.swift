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

    func testWebRouterForwardsOnlyTypedPublicEvidence() async throws {
        let provider = CapturingRAGProvider(answer: "Harbor launches [1].")
        let router = AppSelectedAskMeetingAnswering()
        router.install { .available(provider) }
        let url = try XCTUnwrap(URL(string: "https://example.com/harbor"))
        let citation = AskWebCitation(
            url: url,
            title: "Harbor",
            observedDate: Date(timeIntervalSince1970: 1_787_529_600),
            observedDateKind: .published,
            retrievedAt: Date(timeIntervalSince1970: 1_787_529_700),
            freshness: .recent,
            text: "Harbor launches September 14.",
            isExcerptTruncated: false)

        let answer = try await router.answer(
            question: "When does Harbor launch?",
            citations: [citation])
        let meetingCapture = await provider.snapshot()
        let webCapture = await provider.webSnapshot()

        XCTAssertEqual(answer, "Harbor launches [1].")
        XCTAssertNil(meetingCapture)
        let captured = try XCTUnwrap(webCapture)
        XCTAssertEqual(captured.question, "When does Harbor launch?")
        XCTAssertEqual(captured.passages, [RAGWebPassage(
            url: url,
            title: "Harbor",
            observedDate: citation.observedDate,
            text: citation.text,
            isExcerptTruncated: false)])
    }

    func testNoteRouterForwardsOnlyTypedRawNoteEvidence() async throws {
        let provider = CapturingRAGProvider(answer: "Review Q3 [1].")
        let router = AppSelectedAskMeetingAnswering()
        router.install { .available(provider) }
        let citation = AskNoteCitation(
            noteID: UUID(),
            meetingID: MeetingID(),
            meetingTitle: "Planning",
            author: .localUser,
            authoredAt: Date(timeIntervalSince1970: 1_700_000_012),
            timestamp: 12,
            text: "Review the Q3 budget.",
            provenance: .userContextItem)

        let answer = try await router.answer(
            question: "What should I review?",
            citations: [citation])
        let noteCapture = await provider.noteSnapshot()
        let meetingCapture = await provider.snapshot()
        let webCapture = await provider.webSnapshot()

        XCTAssertEqual(answer, "Review Q3 [1].")
        XCTAssertNil(meetingCapture)
        XCTAssertNil(webCapture)
        let captured = try XCTUnwrap(noteCapture)
        XCTAssertEqual(captured.question, "What should I review?")
        XCTAssertEqual(captured.passages, [RAGNotePassage(
            noteID: citation.noteID,
            meetingID: citation.meetingID,
            meetingTitle: citation.meetingTitle,
            author: "local-user",
            authoredAt: citation.authoredAt,
            timestamp: citation.timestamp,
            text: citation.text)])
    }

    func testInterviewRouterSamplesSelectedEngineAndForwardsOnlyLiveEvidence() async throws {
        let provider = CapturingRAGProvider(answer: "Page the owner [1].")
        let router = AppSelectedAskMeetingAnswering()
        router.install { .available(provider) }
        let meetingID = MeetingID()
        let passage = RAGPassage(
            segmentID: UUID(),
            meetingID: meetingID,
            meetingTitle: "This interview",
            timestamp: 41,
            text: "Me: I would page the database owner.")

        let answer = try await router.answer(
            question: "What would you do first?",
            passages: [passage])
        let providerSnapshot = await provider.snapshot()
        let captured = try XCTUnwrap(providerSnapshot)

        XCTAssertEqual(answer, "Page the owner [1].")
        XCTAssertEqual(captured.question, "What would you do first?")
        XCTAssertEqual(captured.passages, [passage])

        let unavailable = AppSelectedAskMeetingAnswering()
        unavailable.install { .unavailable(.requiresMacOS26) }
        let unavailableAnswer = try await unavailable.answer(
            question: "What would you do first?",
            passages: [passage])
        XCTAssertNil(unavailableAnswer)
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

    struct WebRequest: Sendable {
        let question: String
        let passages: [RAGWebPassage]
    }

    struct NoteRequest: Sendable {
        let question: String
        let passages: [RAGNotePassage]
    }

    let answer: String
    private var request: Request?
    private var webRequest: WebRequest?
    private var noteRequest: NoteRequest?

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

    func answer(
        question: String,
        webPassages: [RAGWebPassage]
    ) async throws -> String {
        webRequest = WebRequest(question: question, passages: webPassages)
        return answer
    }

    func answer(
        question: String,
        notePassages: [RAGNotePassage]
    ) async throws -> String {
        noteRequest = NoteRequest(question: question, passages: notePassages)
        return answer
    }

    func snapshot() -> Request? { request }
    func webSnapshot() -> WebRequest? { webRequest }
    func noteSnapshot() -> NoteRequest? { noteRequest }
}

private actor AskRouterSnapshotProbe {
    private var values: [String] = []
    func record(_ value: String) { values.append(value) }
    func snapshot() -> [String] { values }
}
