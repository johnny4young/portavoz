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
