import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class TranscriptTranslationPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_699_200)

    private func seeded() async throws -> (store: MeetingStore, meeting: Meeting, segment: TranscriptSegment) {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(
            title: "Translated", startedAt: now.addingTimeInterval(-60), endedAt: now, lifecycleState: .ready)
        try await store.save(meeting)
        let segment = TranscriptSegment(
            meetingID: meeting.id, channel: .system, text: "Bienvenidos a la reunión",
            language: "es", startTime: 0, endTime: 4, isFinal: true)
        try await store.save([segment])
        return (store, meeting, segment)
    }

    private func fingerprint(_ meeting: Meeting, _ language: String = "en") -> String {
        TranscriptTranslation.fingerprint(
            meetingID: meeting.id, targetLanguage: language,
            transcriptRevision: meeting.transcriptRevision, correctionRevision: .accepted)
    }

    private func artifact(
        _ meeting: Meeting, segment: TranscriptSegment, text: String = "Welcome to the meeting",
        correctionRevision: TranscriptCorrectionRevision = .accepted
    ) -> TranscriptTranslationArtifact {
        TranscriptTranslationArtifact(
            inputFingerprint: fingerprint(meeting),
            translation: TranscriptTranslation(
                meetingID: meeting.id, targetLanguage: "en",
                sourceTranscriptRevision: meeting.transcriptRevision,
                sourceCorrectionRevision: correctionRevision, lines: [segment.id: text], createdAt: now))
    }

    private func claim(_ store: MeetingStore) async throws -> ProcessingJob {
        let job = try await store.claimNextProcessingJob(
            kinds: [.transcriptTranslation], owner: "worker", leaseDuration: 60, at: now)
        return try XCTUnwrap(job)
    }

    private func lifecycle(_ id: MeetingID, in store: MeetingStore) async throws -> MeetingLifecycleState? {
        try await store.detail(id)?.meeting.lifecycleState
    }

    func testARequestIsIdempotentWhileActiveAndNeverChangesTheMeetingLifecycle() async throws {
        let (store, meeting, _) = try await seeded()
        let first = try await store.requestTranscriptTranslation(
            for: meeting.id, fingerprint: fingerprint(meeting), at: now)
        let again = try await store.requestTranscriptTranslation(
            for: meeting.id, fingerprint: fingerprint(meeting), at: now)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(first.state, .pending)
        let state = try await lifecycle(meeting.id, in: store)
        XCTAssertEqual(state, .ready)
    }

    func testAPublishedTranslationIsStoredAndReplacedPerLanguage() async throws {
        let (store, meeting, segment) = try await seeded()
        _ = try await store.requestTranscriptTranslation(for: meeting.id, fingerprint: fingerprint(meeting), at: now)
        let job = try await claim(store)
        let completed = try await store.completeTranscriptTranslationJob(
            job.id, owner: "worker", artifact: artifact(meeting, segment: segment), at: now)
        XCTAssertEqual(completed.state, .succeeded)
        var stored = try await store.transcriptTranslations(for: meeting.id)
        XCTAssertEqual(stored.map(\.targetLanguage), ["en"])
        XCTAssertEqual(stored.first?.lines, [segment.id: "Welcome to the meeting"])

        let rerun = try await store.requestTranscriptTranslation(
            for: meeting.id, fingerprint: fingerprint(meeting), at: now)
        XCTAssertEqual(rerun.id, job.id, "A settled request runs again under the same identity")
        XCTAssertEqual(rerun.state, .pending)
        let second = try await claim(store)
        _ = try await store.completeTranscriptTranslationJob(
            second.id, owner: "worker", artifact: artifact(meeting, segment: segment, text: "Welcome, everyone"),
            at: now)
        stored = try await store.transcriptTranslations(for: meeting.id)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.lines[segment.id], "Welcome, everyone")
        let state = try await lifecycle(meeting.id, in: store)
        XCTAssertEqual(state, .ready)
    }

    func testAChangedTranscriptOrCorrectionRejectsThePublication() async throws {
        let (store, meeting, segment) = try await seeded()
        _ = try await store.requestTranscriptTranslation(for: meeting.id, fingerprint: fingerprint(meeting), at: now)
        let job = try await claim(store)
        let correction = TranscriptCorrectionEvent(
            meetingID: meeting.id, baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: [segment.id], kind: .replaceText(text: "Bienvenidas", language: "es"),
            sourceDeviceID: UUID(), createdAt: now)
        _ = try await store.appendTranscriptCorrections([correction])
        do {
            _ = try await store.completeTranscriptTranslationJob(
                job.id, owner: "worker", artifact: artifact(meeting, segment: segment), at: now)
            XCTFail("A translation of a superseded reading must not publish")
        } catch StorageError.processingJobInputChanged {}
        let stored = try await store.transcriptTranslations(for: meeting.id)
        XCTAssertTrue(stored.isEmpty)
    }

    func testCancellingStopsTheWorkerAndAFailureNeverNeedsAttention() async throws {
        let (store, meeting, segment) = try await seeded()
        _ = try await store.requestTranscriptTranslation(for: meeting.id, fingerprint: fingerprint(meeting), at: now)
        let job = try await claim(store)
        try await store.cancelTranscriptTranslation(for: meeting.id, at: now)
        do {
            _ = try await store.completeTranscriptTranslationJob(
                job.id, owner: "worker", artifact: artifact(meeting, segment: segment), at: now)
            XCTFail("A cancelled translation must not publish")
        } catch StorageError.processingJobLeaseLost {}

        _ = try await store.requestTranscriptTranslation(for: meeting.id, fingerprint: fingerprint(meeting), at: now)
        let retried = try await claim(store)
        _ = try await store.failProcessingJob(
            retried.id, owner: "worker", failure: ProcessingJobFailure(code: "processing.translation.failed"),
            at: now)
        let state = try await lifecycle(meeting.id, in: store)
        XCTAssertEqual(state, .ready, "An optional translation never marks its meeting as needing attention")
    }

    func testPurgingTheMeetingRemovesItsTranslations() async throws {
        let (store, meeting, segment) = try await seeded()
        _ = try await store.requestTranscriptTranslation(for: meeting.id, fingerprint: fingerprint(meeting), at: now)
        let job = try await claim(store)
        _ = try await store.completeTranscriptTranslationJob(
            job.id, owner: "worker", artifact: artifact(meeting, segment: segment), at: now)
        try await store.delete(meeting.id)
        let hidden = try await store.transcriptTranslations(for: meeting.id)
        XCTAssertTrue(hidden.isEmpty, "A deleted meeting exposes no translation")
        try await store.purge(meeting.id)
        let rows = try await store.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcriptTranslationLine") ?? -1
        }
        XCTAssertEqual(rows, 0)
    }
}
