import ApplicationKit
import Foundation
import PortavozCore
import XCTest

final class CorrectMeetingTranscriptTests: XCTestCase {
    private let meetingID = MeetingID(
        rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!)
    private let sourceID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000002")!
    private let firstSpeaker = SpeakerID(
        rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!)
    private let secondSpeaker = SpeakerID(
        rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000004")!)
    private let sourceDeviceID = UUID(
        uuidString: "00000000-0000-4000-9000-000000000001")!
    private let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

    func testChangingTextAndSpeakerAppendsOneAtomicBatch() async throws {
        let repository = TranscriptCorrectionRepositoryProbe()
        let timestamp = timestamp
        let useCase = CorrectMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp })

        let result = try await useCase.execute(request(
            correctedText: "Corrected evidence",
            correctedSpeakerID: secondSpeaker))

        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.events.count, 2)
        let batches = await repository.appendedBatches()
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0], result.events)
        XCTAssertEqual(Set(result.events.map(\.targetSegmentIDs)), Set([[sourceID]]))
        XCTAssertEqual(Set(result.events.map(\.sourceDeviceID)), [sourceDeviceID])
        XCTAssertEqual(Set(try result.events.map {
            try TranscriptCorrectionPolicy.correctionDomain(of: $0, in: result.events)
        }), [.text, .speaker])
    }

    func testUndoAppendsIndependentRestoreEventsWithoutDeletingHistory() async throws {
        let text = event(
            101,
            kind: .replaceText(text: "Corrected evidence", language: "en"),
            at: 1)
        let speaker = event(
            102,
            kind: .changeSpeaker(secondSpeaker),
            at: 2)
        let repository = TranscriptCorrectionRepositoryProbe(history: [text, speaker])
        let timestamp = timestamp
        let useCase = CorrectMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp })

        let result = try await useCase.execute(request(
            correctedText: originalRow.text,
            correctedSpeakerID: firstSpeaker))

        XCTAssertEqual(result.events.count, 2)
        XCTAssertTrue(result.events.allSatisfy {
            if case .restore = $0.kind { return true }
            return false
        })
        XCTAssertEqual(
            Set(result.events.compactMap(\.supersedesCorrectionID)),
            [text.id, speaker.id])
        let history = await repository.history()
        XCTAssertEqual(history, [text, speaker] + result.events)
    }

    func testSubsequentEditSupersedesTheTerminalInItsOwnDomain() async throws {
        let text = event(
            101,
            kind: .replaceText(text: "First correction", language: "en"),
            at: 1)
        let speaker = event(
            102,
            kind: .changeSpeaker(secondSpeaker),
            at: 2)
        let repository = TranscriptCorrectionRepositoryProbe(history: [text, speaker])
        let timestamp = timestamp
        let useCase = CorrectMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp })

        let result = try await useCase.execute(request(
            correctedText: "Second correction",
            correctedSpeakerID: secondSpeaker))

        XCTAssertEqual(result.events.count, 1)
        XCTAssertEqual(result.events.first?.supersedesCorrectionID, text.id)
        guard case .replaceText(let replacement, _) = result.events.first?.kind else {
            return XCTFail("the text lane must append a replacement")
        }
        XCTAssertEqual(replacement, "Second correction")
    }

    func testUnchangedCorrectionIsANoOp() async throws {
        let repository = TranscriptCorrectionRepositoryProbe()
        let timestamp = timestamp
        let useCase = CorrectMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp })

        let result = try await useCase.execute(request(
            correctedText: originalRow.text,
            correctedSpeakerID: firstSpeaker))

        XCTAssertFalse(result.changed)
        let batches = await repository.appendedBatches()
        XCTAssertTrue(batches.isEmpty)
    }

    func testUndoRecognizesExactOriginalEvidenceBeforeTrimmingInput() async throws {
        let text = event(
            101,
            kind: .replaceText(text: "Edited evidence", language: "en"),
            at: 1)
        let repository = TranscriptCorrectionRepositoryProbe(history: [text])
        let timestamp = timestamp
        let useCase = CorrectMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp })
        let original = MeetingTranscriptContent.Row(
            id: sourceID,
            sourceSegmentIDs: [sourceID],
            speakerID: firstSpeaker,
            channel: .system,
            text: " Original evidence ",
            language: "en",
            startTime: 0,
            endTime: 4,
            confidence: 0.9,
            isFinal: true)

        let result = try await useCase.execute(CorrectMeetingTranscriptRequest(
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            original: original,
            correctedText: original.text,
            correctedSpeakerID: firstSpeaker))

        XCTAssertEqual(result.events.count, 1)
        guard case .restore = result.events[0].kind else {
            return XCTFail("exact accepted evidence must append a restore event")
        }
        XCTAssertEqual(result.events[0].supersedesCorrectionID, text.id)
    }

    func testStructuralCorrectionBlocksPropertyEditorAndInvalidTextFailsEarly() async {
        let structural = event(101, kind: .suppress, at: 1)
        let repository = TranscriptCorrectionRepositoryProbe(history: [structural])
        let timestamp = timestamp
        let useCase = CorrectMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp })

        await assertError(.incompatibleStructuralCorrection) {
            _ = try await useCase.execute(self.request(
                correctedText: "Correction",
                correctedSpeakerID: self.firstSpeaker))
        }
        await assertError(.invalidText) {
            _ = try await useCase.execute(self.request(
                correctedText: " … ",
                correctedSpeakerID: self.firstSpeaker))
        }
        let batches = await repository.appendedBatches()
        XCTAssertTrue(batches.isEmpty)
    }

    func testCyclicRestoreHistoryFailsClosedInsteadOfRecursing() async {
        let firstID = UUID(
            uuidString: "00000000-0000-4000-8000-000000000201")!
        let secondID = UUID(
            uuidString: "00000000-0000-4000-8000-000000000202")!
        let first = TranscriptCorrectionEvent(
            id: firstID,
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [sourceID],
            kind: .restore,
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp.addingTimeInterval(1),
            supersedesCorrectionID: secondID)
        let second = TranscriptCorrectionEvent(
            id: secondID,
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [sourceID],
            kind: .restore,
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp.addingTimeInterval(2),
            supersedesCorrectionID: firstID)
        let repository = TranscriptCorrectionRepositoryProbe(history: [first, second])
        let timestamp = timestamp
        let useCase = CorrectMeetingTranscript(
            repository: repository,
            sourceDeviceID: sourceDeviceID,
            now: { timestamp })

        do {
            _ = try await useCase.execute(request(
                correctedText: "Corrected",
                correctedSpeakerID: firstSpeaker))
            XCTFail("cyclic correction history must fail closed")
        } catch {
            let batches = await repository.appendedBatches()
            XCTAssertTrue(batches.isEmpty)
        }
    }

    func testMeetingDetailComposesCurrentReadingButKeepsOriginalEvidence() throws {
        let meeting = Meeting(
            id: meetingID,
            title: "Correction review",
            startedAt: timestamp,
            transcriptRevision: 7)
        let first = Speaker(id: firstSpeaker, meetingID: meetingID, label: "S1")
        let second = Speaker(id: secondSpeaker, meetingID: meetingID, label: "S2")
        let segment = TranscriptSegment(
            id: sourceID,
            meetingID: meetingID,
            speakerID: firstSpeaker,
            channel: .system,
            text: originalRow.text,
            language: "en",
            startTime: 0,
            endTime: 4,
            confidence: 0.9,
            isFinal: true)
        let text = event(
            101,
            kind: .replaceText(text: "Corrected evidence", language: "en"),
            at: 1)
        let speaker = event(
            102,
            kind: .changeSpeaker(secondSpeaker),
            at: 2)
        let detail = MeetingReviewReadModel(
            core: MeetingReviewCore(
                meeting: meeting,
                speakers: [first, second],
                segments: [segment],
                corrections: [text, speaker],
                isRefinedTranscript: true),
            summary: nil,
            companionCards: [],
            privacyReceipt: nil,
            processingJobs: [])

        let row = try XCTUnwrap(detail.transcriptContent().rows.first)
        let context = try XCTUnwrap(detail.transcriptCorrectionEditorContext(for: row))

        XCTAssertEqual(row.text, "Corrected evidence")
        XCTAssertEqual(row.speakerID, secondSpeaker)
        XCTAssertEqual(context.original.text, originalRow.text)
        XCTAssertEqual(context.original.speakerID, firstSpeaker)
        XCTAssertTrue(context.hasTextCorrection)
        XCTAssertTrue(context.hasSpeakerCorrection)
        XCTAssertFalse(context.hasStructuralCorrection)
    }
}

private extension CorrectMeetingTranscriptTests {
    var originalRow: MeetingTranscriptContent.Row {
        MeetingTranscriptContent.Row(
            id: sourceID,
            sourceSegmentIDs: [sourceID],
            speakerID: firstSpeaker,
            channel: .system,
            text: "Original evidence",
            language: "en",
            startTime: 0,
            endTime: 4,
            confidence: 0.9,
            isFinal: true)
    }

    func request(
        correctedText: String,
        correctedSpeakerID: SpeakerID?
    ) -> CorrectMeetingTranscriptRequest {
        CorrectMeetingTranscriptRequest(
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            original: originalRow,
            correctedText: correctedText,
            correctedSpeakerID: correctedSpeakerID)
    }

    func event(
        _ value: Int,
        kind: TranscriptCorrectionKind,
        at offset: TimeInterval
    ) -> TranscriptCorrectionEvent {
        TranscriptCorrectionEvent(
            id: UUID(uuidString: String(
                format: "00000000-0000-4000-8000-%012d",
                value))!,
            meetingID: meetingID,
            baseTranscriptRevision: 7,
            targetSegmentIDs: [sourceID],
            kind: kind,
            sourceDeviceID: sourceDeviceID,
            createdAt: timestamp.addingTimeInterval(offset))
    }

    func assertError(
        _ expected: CorrectMeetingTranscriptError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("expected \(expected)")
        } catch let error as CorrectMeetingTranscriptError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

private actor TranscriptCorrectionRepositoryProbe: TranscriptCorrectionRepository {
    private var storedHistory: [TranscriptCorrectionEvent]
    private var batches: [[TranscriptCorrectionEvent]] = []

    init(history: [TranscriptCorrectionEvent] = []) {
        storedHistory = history
    }

    func transcriptCorrectionHistory(
        for meetingID: MeetingID
    ) -> [TranscriptCorrectionEvent] {
        storedHistory.filter { $0.meetingID == meetingID }
    }

    func appendTranscriptCorrections(
        _ events: [TranscriptCorrectionEvent]
    ) -> [TranscriptCorrectionEvent] {
        batches.append(events)
        storedHistory.append(contentsOf: events)
        return events
    }

    func history() -> [TranscriptCorrectionEvent] { storedHistory }
    func appendedBatches() -> [[TranscriptCorrectionEvent]] { batches }
}
