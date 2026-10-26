import ApplicationKit
import Foundation
import PortavozCore
import XCTest
@testable import portavoz_app

final class MeetingTranscriptTranslationStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_699_200)
    private lazy var meeting = Meeting(title: "Bilingual", startedAt: now, lifecycleState: .ready)
    private lazy var segment = TranscriptSegment(
        meetingID: meeting.id, channel: .system, text: "Hola a todos", language: "es",
        startTime: 0, endTime: 2, isFinal: true)

    private func detail(
        jobs: [ProcessingJob] = [], translations: [TranscriptTranslation] = []
    ) -> MeetingReviewReadModel {
        MeetingReviewReadModel(
            core: MeetingReviewCore(meeting: meeting, speakers: [], segments: [segment]),
            summary: nil, companionCards: [], privacyReceipt: nil, processingJobs: jobs,
            translations: translations)
    }

    private func job(_ state: ProcessingJobState, code: String? = nil, at offset: TimeInterval = 0) -> ProcessingJob {
        ProcessingJob(
            meetingID: meeting.id, kind: .transcriptTranslation, inputFingerprint: "f", state: state,
            errorCode: code, createdAt: now.addingTimeInterval(offset))
    }

    private func translation(revision: Int = 0) -> TranscriptTranslation {
        TranscriptTranslation(
            meetingID: meeting.id, targetLanguage: "en", sourceTranscriptRevision: revision,
            sourceCorrectionRevision: .accepted, lines: [segment.id: "Hello everyone"], createdAt: now)
    }

    func testTheLatestJobDecidesWhatTheHeaderOffers() {
        XCTAssertEqual(MeetingTranscriptTranslationState(detail()).activity, .idle)
        XCTAssertEqual(MeetingTranscriptTranslationState(detail(jobs: [job(.running)])).activity, .translating)
        XCTAssertEqual(
            MeetingTranscriptTranslationState(detail(jobs: [
                job(.running, at: 0),
                job(.cancelled, code: TranscriptTranslationFailure.languagesMissing.code, at: 1)
            ])).activity,
            .failed(missingLanguages: true))
        XCTAssertEqual(MeetingTranscriptTranslationState(detail(jobs: [job(.failed)])).activity,
                       .failed(missingLanguages: false))
        XCTAssertEqual(
            MeetingTranscriptTranslationState(detail(jobs: [job(.cancelled, code: "translation.cancelled")])).activity,
            .idle)
        let summaryJob = ProcessingJob(meetingID: meeting.id, kind: .summary, inputFingerprint: "s", state: .running)
        XCTAssertEqual(MeetingTranscriptTranslationState(detail(jobs: [summaryJob])).activity, .idle)
    }

    func testATranslationOfAnOlderRevisionIsOutOfDate() {
        XCTAssertTrue(MeetingTranscriptTranslationState(detail(translations: [translation()])).isCurrent("en"))
        XCTAssertFalse(
            MeetingTranscriptTranslationState(detail(translations: [translation(revision: 3)])).isCurrent("en"))
        XCTAssertFalse(MeetingTranscriptTranslationState(detail()).isCurrent("es"))
    }

    func testTheTranslatedReadingReplacesOnlyTranslatedRows() {
        let english = TranscriptSegment(
            meetingID: meeting.id, channel: .system, text: "Already English", language: "en",
            startTime: 3, endTime: 4, isFinal: true)
        let model = MeetingReviewReadModel(
            core: MeetingReviewCore(meeting: meeting, speakers: [], segments: [segment, english]),
            summary: nil, companionCards: [], privacyReceipt: nil, processingJobs: [])
        let shown = MeetingTranscriptTranslationState.display(model.transcriptContent(), translation: translation())
        XCTAssertEqual(shown.rows.map(\.text), ["Hello everyone", "Already English"])
        XCTAssertEqual(shown.rows.map(\.id), [segment.id, english.id])
        XCTAssertEqual(
            MeetingTranscriptTranslationState.display(model.transcriptContent(), translation: nil).rows.map(\.text),
            ["Hola a todos", "Already English"])
    }
}
