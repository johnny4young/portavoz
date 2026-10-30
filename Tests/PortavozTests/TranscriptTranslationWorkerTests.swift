import ApplicationKit
import DiarizationKit
import Foundation
import PortavozCore
import StorageKit
import TranscriptionKit
import XCTest

final class TranscriptTranslationWorkerTests: XCTestCase {
    private struct Translator: DictationTextTranslating {
        let reply: @Sendable (String, String, String) async throws -> String

        func translate(_ text: String, from source: String, to target: String) async throws -> String {
            try await reply(text, source, target)
        }
    }

    /// The translation lane needs none of the audio, summary or completion ports.
    private struct Unused: PostCaptureAudioProcessing, PostCaptureSummaryConfiguration, PostCaptureCompletionActions {
        func transcribePostCaptureAudio(
            _ asset: AudioAsset, channel: AudioChannel, hints: TranscriptionHints
        ) async throws -> FileTranscription { throw CancellationError() }
        func currentPostCaptureVoiceprint() async -> Voiceprint? { nil }
        func diarizePostCaptureAudio(_ asset: AudioAsset, voiceprint: Voiceprint?) async throws -> [SpeakerTurn] {
            []
        }
        func schedulePostCaptureIdleRelease() async {}
        func postCaptureSummaryProvider() async -> PostCaptureSummaryProviderSelection? { nil }
        func postCaptureSummaryPreferences(spokenLanguage: String?) async -> PostCaptureSummaryPreferences {
            PostCaptureSummaryPreferences(outputLanguage: "es", vocabulary: [])
        }
        func runPostMeetingAction(for meetingID: MeetingID) async {}
    }

    private let now = Date(timeIntervalSince1970: 1_783_699_200)

    private actor HeldTranslation {
        private var calls: [String] = []
        private var continuation: CheckedContinuation<Void, Never>?

        func translate(_ text: String, started: XCTestExpectation) async -> String {
            calls.append(text)
            if calls.count == 1 {
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    started.fulfill()
                }
            }
            return "EN " + text
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }

        func translatedTexts() -> [String] { calls }
    }

    private func seeded(_ texts: [(String, String?)]) async throws -> (MeetingStore, Meeting, [TranscriptSegment]) {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Bilingual", startedAt: now.addingTimeInterval(-60), endedAt: now,
                              lifecycleState: .ready)
        try await store.save(meeting)
        let segments = texts.enumerated().map { index, item in
            TranscriptSegment(
                meetingID: meeting.id, channel: .system, text: item.0, language: item.1,
                startTime: Double(index * 5), endTime: Double(index * 5 + 4), isFinal: true)
        }
        try await store.save(segments)
        return (store, meeting, segments)
    }

    private func drain(
        _ store: MeetingStore, reply: @escaping @Sendable (String, String, String) async throws -> String
    ) async {
        let workflow = ProcessPostCaptureJobs(
            store: store, capabilities: Unused(),
            translation: TranscriptTranslationWorker(store: store, translator: Translator(reply: reply)),
            now: { [now] in now })
        _ = await workflow.execute(ProcessPostCaptureJobsRequest(owner: "test-worker"))
    }

    private func request(_ store: MeetingStore, _ meetingID: MeetingID, into language: String = "en") async throws {
        let reading = try await store.transcriptTranslationReading(meetingID)
        let core = try XCTUnwrap(reading)
        _ = try await RequestTranscriptTranslation(store: store)(core, into: language, at: now)
    }

    func testOnlyRowsInTheOtherLanguageAreTranslated() async throws {
        let (store, meeting, segments) = try await seeded([
            ("Bienvenidos a la reunión de hoy", "es"),
            ("Let's review the roadmap together", "en"),
            ("Ok", nil),
            ("Necesitamos cerrar el presupuesto pronto", nil)
        ])
        try await request(store, meeting.id)
        await drain(store) { text, source, target in
            XCTAssertEqual(source, "es")
            XCTAssertEqual(target, "en")
            return "EN " + text
        }
        let translations = try await store.transcriptTranslations(for: meeting.id)
        let translation = try XCTUnwrap(translations.first)
        XCTAssertEqual(translation.targetLanguage, "en")
        XCTAssertEqual(translation.lines, [
            segments[0].id: "EN Bienvenidos a la reunión de hoy",
            segments[3].id: "EN Necesitamos cerrar el presupuesto pronto"
        ])
        let lifecycle = try await store.detail(meeting.id)?.meeting.lifecycleState
        XCTAssertEqual(lifecycle, .ready)
    }

    func testMissingLanguagesEndTheJobForGoodWithItsReason() async throws {
        let (store, meeting, _) = try await seeded([("Bienvenidos a la reunión de hoy", "es")])
        try await request(store, meeting.id)
        await drain(store) { _, _, _ in throw DictationTranslationUnavailable(.notInstalled) }
        let jobs = try await store.processingJobs(for: meeting.id)
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.state, .cancelled)
        XCTAssertEqual(job.errorCode, TranscriptTranslationFailure.languagesMissing.code)
        let stored = try await store.transcriptTranslations(for: meeting.id)
        XCTAssertTrue(stored.isEmpty)
        let lifecycle = try await store.detail(meeting.id)?.meeting.lifecycleState
        XCTAssertEqual(lifecycle, .ready)
    }

    /// Holds the first row in flight, applies `interrupt` to the store, then releases it.
    private func drainInterrupted(
        _ store: MeetingStore,
        interrupt: (HeldTranslation) async throws -> Void
    ) async throws -> (result: ProcessPostCaptureJobsResult, texts: [String]) {
        let started = expectation(description: "First translation is held in flight")
        let translator = HeldTranslation()
        let workflow = ProcessPostCaptureJobs(
            store: store, capabilities: Unused(),
            translation: TranscriptTranslationWorker(store: store, translator: Translator { text, _, _ in
                await translator.translate(text, started: started)
            }),
            now: { [now] in now })
        let drain = Task { await workflow.execute(ProcessPostCaptureJobsRequest(owner: "test-worker")) }
        await fulfillment(of: [started], timeout: 5)
        do {
            try await interrupt(translator)
        } catch {
            await translator.release()
            drain.cancel()
            _ = await drain.value
            throw error
        }
        await translator.release()
        let result = await drain.value
        return (result, await translator.translatedTexts())
    }

    func testALeaseReclaimedByAnotherOwnerStopsTranslationQuietly() async throws {
        let firstText = "Bienvenidos a la reunión de hoy"
        let (store, meeting, _) = try await seeded([(firstText, "es"), ("Necesitamos cerrar el presupuesto pronto", "es")])
        try await request(store, meeting.id)
        let (result, texts) = try await drainInterrupted(store) { _ in
            // The first lease expired: recovery hands the job to another worker.
            let reclaimed = try await store.claimNextProcessingJob(
                kinds: [.transcriptTranslation], owner: "other-worker", leaseDuration: 60,
                at: now.addingTimeInterval(3_600))
            XCTAssertNotNil(reclaimed)
        }
        XCTAssertEqual(texts, [firstText])
        XCTAssertTrue(result.issues.isEmpty)
        let jobs = try await store.processingJobs(for: meeting.id)
        XCTAssertEqual(jobs.first?.leaseOwner, "other-worker", "The new owner's work is left intact")
        let stored = try await store.transcriptTranslations(for: meeting.id)
        XCTAssertTrue(stored.isEmpty)
    }

    func testAMeetingPurgedMidTranslationStopsWithoutAProcessingIssue() async throws {
        let firstText = "Bienvenidos a la reunión de hoy"
        let (store, meeting, _) = try await seeded([(firstText, "es"), ("Necesitamos cerrar el presupuesto pronto", "es")])
        try await request(store, meeting.id)
        let (result, texts) = try await drainInterrupted(store) { _ in
            try await store.delete(meeting.id)
            try await store.purge(meeting.id)
        }
        XCTAssertEqual(texts, [firstText])
        XCTAssertTrue(result.issues.isEmpty, "Work that no longer exists is not a failure")
    }

    func testCancellingBetweenRowsStopsTranslationAndDrainsTheNextJob() async throws {
        let firstText = "Bienvenidos a la reunión de hoy"
        let secondText = "Necesitamos cerrar el presupuesto pronto"
        let nextText = "Esta es la siguiente reunión"
        let (store, meeting, _) = try await seeded([(firstText, "es"), (secondText, "es")])
        try await request(store, meeting.id)
        let started = expectation(description: "First translation is held in flight")
        let translator = HeldTranslation()
        let workflow = ProcessPostCaptureJobs(
            store: store, capabilities: Unused(),
            translation: TranscriptTranslationWorker(store: store, translator: Translator { text, _, _ in
                await translator.translate(text, started: started)
            }),
            now: { [now] in now })
        let drain = Task { await workflow.execute(ProcessPostCaptureJobsRequest(owner: "test-worker")) }
        await fulfillment(of: [started], timeout: 5)
        do {
            try await store.cancelTranscriptTranslation(for: meeting.id, at: now)
            let next = Meeting(title: "Next", startedAt: now.addingTimeInterval(-60), endedAt: now,
                               lifecycleState: .ready)
            try await store.save(next)
            try await store.save([TranscriptSegment(
                meetingID: next.id, channel: .system, text: nextText, language: "es",
                startTime: 0, endTime: 4, isFinal: true)])
            try await request(store, next.id)
            await translator.release()
            let result = await drain.value
            let texts = await translator.translatedTexts()
            XCTAssertEqual(texts, [firstText, nextText], "Cancelled work must yield before translating another row")
            XCTAssertEqual(result.processedJobCount, 2)
            XCTAssertTrue(result.issues.isEmpty)
            let jobs = try await store.processingJobs(for: meeting.id)
            let cancelled = try XCTUnwrap(jobs.first)
            XCTAssertEqual(cancelled.state, .cancelled)
            XCTAssertEqual(cancelled.errorCode, "translation.cancelled")
            XCTAssertNil(cancelled.notBefore)
            let stored = try await store.transcriptTranslations(for: meeting.id)
            XCTAssertTrue(stored.isEmpty)
            let nextTranslations = try await store.transcriptTranslations(for: next.id)
            XCTAssertEqual(nextTranslations.first?.lines.values.first, "EN " + nextText)
            let lifecycle = try await store.detail(meeting.id)?.meeting.lifecycleState
            XCTAssertEqual(lifecycle, .ready)
        } catch {
            await translator.release()
            drain.cancel()
            _ = await drain.value
            throw error
        }
    }

    func testATranscriptChangedAfterTheRequestIsNotTranslated() async throws {
        let (store, meeting, segments) = try await seeded([("Bienvenidos a la reunión de hoy", "es")])
        try await request(store, meeting.id)
        _ = try await store.appendTranscriptCorrections([TranscriptCorrectionEvent(
            meetingID: meeting.id, baseTranscriptRevision: meeting.transcriptRevision,
            targetSegmentIDs: [segments[0].id], kind: .replaceText(text: "Bienvenidas a la reunión", language: "es"),
            sourceDeviceID: UUID(), createdAt: now)])
        await drain(store) { _, _, _ in
            XCTFail("A superseded reading is never sent to the translator")
            return ""
        }
        let jobs = try await store.processingJobs(for: meeting.id)
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.state, .cancelled)
        let stored = try await store.transcriptTranslations(for: meeting.id)
        XCTAssertTrue(stored.isEmpty)
    }

    func testWithoutATranslatorTheLaneIsNeverClaimed() async throws {
        let (store, meeting, _) = try await seeded([("Bienvenidos a la reunión de hoy", "es")])
        try await request(store, meeting.id)
        let workflow = ProcessPostCaptureJobs(store: store, capabilities: Unused(), now: { [now] in now })
        let result = await workflow.execute(ProcessPostCaptureJobsRequest(owner: "test-worker"))
        XCTAssertEqual(result.processedJobCount, 0)
        let jobs = try await store.processingJobs(for: meeting.id)
        let job = try XCTUnwrap(jobs.first)
        XCTAssertEqual(job.state, .pending)
    }
}
