import ApplicationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class CommitmentLinkObservationTests: XCTestCase {
    private let baseDate = Date(timeIntervalSince1970: 1_785_600_000)

    func testTargetReadReturnsExactOpenContinuityEvidence() async throws {
        let fixture = try await makeFixture()

        let targets = try await fixture.store.commitmentLinkSuggestionTargets()

        XCTAssertEqual(targets.count, 1)
        XCTAssertEqual(targets.first?.commitment.id, fixture.commitmentID)
        XCTAssertEqual(targets.first?.sourceMeetingIDs, [fixture.sourceMeetingID])
        XCTAssertEqual(
            targets.first?.evidenceSegmentIDs,
            [fixture.evidenceSegmentID])

        _ = try await fixture.store.applyCommitmentTransition(
            .complete,
            to: fixture.commitmentID,
            at: baseDate.addingTimeInterval(1))
        let closedTargets = try await fixture.store.commitmentLinkSuggestionTargets()
        XCTAssertTrue(closedTargets.isEmpty)
        let invalidLimit = try await fixture.store.commitmentLinkSuggestionTargets(limit: 0)
        XCTAssertTrue(invalidLimit.isEmpty)
    }

    func testTargetReadRejectsOverBoundedSourceHistoryWithoutTruncating() async throws {
        let fixture = try await makeFixture()
        let sourceBaseDate = baseDate
        try await fixture.store.database.write { database in
            for index in 0..<CommitmentLinkSuggestionPolicy.maximumRelatedRowCount {
                let source = CommitmentSource(
                    commitmentID: fixture.commitmentID,
                    kind: .manual,
                    meetingID: nil,
                    firstSeenAt: sourceBaseDate.addingTimeInterval(Double(index + 1)))
                try CommitmentSourceRecord(source).insert(database)
            }
        }

        let targets = try await fixture.store.commitmentLinkSuggestionTargets()

        XCTAssertTrue(targets.isEmpty)
    }

    func testObservationUsesExistingSemanticPortAndExactOwnerWithoutDownloading() async throws {
        let fixture = try await makeFixture()
        let runtime = RecordingCommitmentLinkRuntime(profile: fixture.profile)
        let observer = ObserveCommitmentLinkSuggestions(
            store: fixture.store,
            runtime: runtime)
        let request = ObserveCommitmentLinkSuggestionsRequest(
            sourceMeetingID: MeetingID(),
            actionItemID: UUID(),
            candidateText: "Continue the rollout checklist",
            candidateAssignee: .person(fixture.personID))

        let observation = try await observer.execute(request)

        XCTAssertEqual(
            observation.semanticProfileFingerprint,
            fixture.profile.fingerprint)
        XCTAssertEqual(
            observation.semanticHits,
            [CommitmentLinkSemanticHit(
                segmentID: fixture.evidenceSegmentID,
                similarity: 1)])
        XCTAssertEqual(observation.semanticHitSegmentIDs, [fixture.evidenceSegmentID])
        XCTAssertEqual(observation.suggestions.map(\.commitment.id), [fixture.commitmentID])
        XCTAssertEqual(
            observation.suggestions.first?.matchedEvidenceSegmentIDs,
            [fixture.evidenceSegmentID])
        let assetDownloadRequests = await runtime.assetDownloadRequests
        XCTAssertEqual(assetDownloadRequests, [false])
    }

    func testObservationSeparatesSemanticRelevanceFromWrongOwnerAdmission() async throws {
        let fixture = try await makeFixture()
        let observer = ObserveCommitmentLinkSuggestions(
            store: fixture.store,
            runtime: RecordingCommitmentLinkRuntime(profile: fixture.profile))

        let observation = try await observer.execute(
            ObserveCommitmentLinkSuggestionsRequest(
                sourceMeetingID: MeetingID(),
                actionItemID: UUID(),
                candidateText: "Continue the rollout checklist",
                candidateAssignee: .person(PersonID())))

        XCTAssertEqual(observation.semanticHitSegmentIDs, [fixture.evidenceSegmentID])
        XCTAssertTrue(observation.suggestions.isEmpty)
    }

    func testObservationRejectsUnavailableAssetsAndMalformedCandidateText() async throws {
        let fixture = try await makeFixture()
        let unavailable = ObserveCommitmentLinkSuggestions(
            store: fixture.store,
            runtime: UnavailableCommitmentLinkRuntime())
        let request = ObserveCommitmentLinkSuggestionsRequest(
            sourceMeetingID: MeetingID(),
            actionItemID: UUID(),
            candidateText: "Continue the rollout checklist",
            candidateAssignee: .person(fixture.personID))

        await assertCommitmentLinkError(.semanticUnavailable) {
            _ = try await unavailable.execute(request)
        }

        let available = ObserveCommitmentLinkSuggestions(
            store: fixture.store,
            runtime: RecordingCommitmentLinkRuntime(profile: fixture.profile))
        await assertCommitmentLinkError(.invalidCandidateText) {
            _ = try await available.execute(ObserveCommitmentLinkSuggestionsRequest(
                sourceMeetingID: request.sourceMeetingID,
                actionItemID: request.actionItemID,
                candidateText: "   ",
                candidateAssignee: request.candidateAssignee))
        }
    }

    func testObservationRejectsMissingNonFiniteAndAscendingSemanticSimilarity() async throws {
        let fixture = try await makeFixture()
        let baseHit = SearchHit(
            meetingID: fixture.sourceMeetingID,
            meetingTitle: "Earlier planning",
            segmentID: fixture.evidenceSegmentID,
            text: "Finish the rollout checklist",
            snippet: "Finish the rollout checklist",
            startTime: 1,
            transcriptRevision: 0)
        let request = ObserveCommitmentLinkSuggestionsRequest(
            sourceMeetingID: MeetingID(),
            actionItemID: UUID(),
            candidateText: "Continue the rollout checklist",
            candidateAssignee: .person(fixture.personID))
        let invalidHitSets = [
            [baseHit],
            [copy(baseHit, segmentID: UUID(), semanticSimilarity: .nan)],
            [
                copy(baseHit, segmentID: UUID(), semanticSimilarity: 0.4),
                copy(baseHit, segmentID: UUID(), semanticSimilarity: 0.8),
            ],
        ]

        for hits in invalidHitSets {
            let observer = ObserveCommitmentLinkSuggestions(
                store: fixture.store,
                runtime: RecordingCommitmentLinkRuntime(profile: fixture.profile),
                semanticIndex: FixedCommitmentLinkSemanticIndex(hits: hits))
            await assertCommitmentLinkError(.invalidSemanticSimilarity) {
                _ = try await observer.execute(request)
            }
        }
    }

    private func makeFixture() async throws -> CommitmentLinkObservationFixture {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Earlier planning", startedAt: baseDate)
        let speaker = Speaker(
            meetingID: meeting.id,
            label: "S1",
            displayName: "Mara")
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .system,
            text: "Mara will finish the rollout checklist on Friday.",
            startTime: 1,
            endTime: 4,
            isFinal: true)
        try await store.save(meeting)
        try await store.save([speaker])
        try await store.save([segment])
        let person = try await store.createPersonAndLink(
            speakerID: speaker.id,
            preferredName: "Mara",
            source: .manualName)
        let item = ActionItem(
            text: "Finish the rollout checklist",
            ownerSpeakerID: speaker.id)
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meeting.id,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "Mara will finish the rollout checklist.",
            actionItems: [item],
            actionItemEvidence: [SummaryActionItemEvidence(
                actionItemID: item.id,
                evidenceSegmentIDs: [segment.id])]))
        let confirmation = try await store.confirmCommitment(
            CommitmentConfirmation(
                title: "Finish the rollout checklist",
                canonicalPersonID: person.person.id,
                origin: .generatedActionItem(item.id)),
            at: baseDate)
        let profile = semanticTestProfile()
        let candidates = try await store.segmentsNeedingEmbeddings(limit: 10)
        _ = try await store.storeEmbeddings(
            [segment.id: [1, 0]],
            for: candidates,
            profile: profile)
        return CommitmentLinkObservationFixture(
            store: store,
            sourceMeetingID: meeting.id,
            evidenceSegmentID: segment.id,
            personID: person.person.id,
            commitmentID: confirmation.commitment.id,
            profile: profile)
    }

    private func copy(
        _ hit: SearchHit,
        segmentID: UUID,
        semanticSimilarity: Float?
    ) -> SearchHit {
        SearchHit(
            meetingID: hit.meetingID,
            meetingTitle: hit.meetingTitle,
            segmentID: segmentID,
            text: hit.text,
            snippet: hit.snippet,
            startTime: hit.startTime,
            transcriptRevision: hit.transcriptRevision,
            semanticSimilarity: semanticSimilarity)
    }
}

private struct CommitmentLinkObservationFixture {
    let store: MeetingStore
    let sourceMeetingID: MeetingID
    let evidenceSegmentID: UUID
    let personID: PersonID
    let commitmentID: CommitmentID
    let profile: SemanticEmbeddingProfile
}

private actor RecordingCommitmentLinkRuntime: SemanticEmbeddingRuntimeClient {
    let profile: SemanticEmbeddingProfile
    private(set) var assetDownloadRequests: [Bool] = []

    init(profile: SemanticEmbeddingProfile) {
        self.profile = profile
    }

    var hasAvailableAssets: Bool { true }

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile? { profile }

    func prepare(allowAssetDownload: Bool) {
        assetDownloadRequests.append(allowAssetDownload)
    }

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload: Bool,
        operation: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        assetDownloadRequests.append(allowAssetDownload)
        return try await operation(CommitmentLinkEmbedding(profile: profile))
    }
}

private struct CommitmentLinkEmbedding: SemanticTextEmbedding {
    let profile: SemanticEmbeddingProfile

    func semanticEmbeddingProfile() -> SemanticEmbeddingProfile { profile }

    func vectors(for texts: [String]) -> [[Float]] {
        texts.map { _ in [1, 0] }
    }
}

private struct UnavailableCommitmentLinkRuntime: SemanticEmbeddingRuntimeClient {
    var hasAvailableAssets: Bool { get async { false } }

    func semanticEmbeddingProfile() async -> SemanticEmbeddingProfile? { nil }

    func prepare(allowAssetDownload _: Bool) async throws {}

    func withPreparedEmbedding<Result: Sendable>(
        allowAssetDownload _: Bool,
        operation _: @Sendable (
            _ embedder: any SemanticTextEmbedding
        ) async throws -> Result
    ) async throws -> Result {
        throw ObserveCommitmentLinkSuggestionsError.semanticUnavailable
    }
}

private struct FixedCommitmentLinkSemanticIndex: SemanticIndexSearching {
    let hits: [SearchHit]

    func search(
        _ query: [Float],
        profile: SemanticEmbeddingProfile,
        limit: Int
    ) async throws -> [SearchHit] {
        Array(hits.prefix(limit))
    }
}

private func assertCommitmentLinkError(
    _ expected: ObserveCommitmentLinkSuggestionsError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected commitment-link observation error", file: file, line: line)
    } catch {
        XCTAssertEqual(
            error as? ObserveCommitmentLinkSuggestionsError,
            expected,
            file: file,
            line: line)
    }
}
