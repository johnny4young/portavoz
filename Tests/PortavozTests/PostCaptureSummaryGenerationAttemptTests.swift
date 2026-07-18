import Foundation
import ApplicationKit
import IntelligenceKit
import PortavozCore
import XCTest

@testable import portavoz_app

final class PostCaptureSummaryGenerationAttemptTests: XCTestCase {
    func testSuccessfulRunContainsReproducibleMetadataWithoutMeetingContent() throws {
        let fixture = Fixture()
        let runID = GenerationRunID()
        let finishedAt = fixture.startedAt.addingTimeInterval(3)
        let run = fixture.attempt.finish(
            outcome: .succeeded,
            draft: fixture.draft,
            at: finishedAt,
            id: runID)

        XCTAssertEqual(run.id, runID)
        XCTAssertEqual(run.meetingID, fixture.meetingID)
        XCTAssertEqual(run.providerID, "durable-provider")
        XCTAssertEqual(run.modelID, "durable-model")
        XCTAssertEqual(run.modelRevision, "pinned-revision")
        XCTAssertEqual(run.inputFingerprint, "summary-operation-fingerprint")
        XCTAssertEqual(run.outputLanguage, "es")
        XCTAssertEqual(run.startedAt, fixture.startedAt)
        XCTAssertEqual(run.finishedAt, finishedAt)
        XCTAssertEqual(run.outcome, .succeeded)
        XCTAssertEqual(
            run.configJSON,
            #"{"attempt":2,"jobID":"31313131-3131-3131-3131-313131313131","#
                + #""operation":"generate","recipeID":"general","#
                + #""sourceTranscriptRevision":7,"workflow":"post-capture"}"#)
        XCTAssertEqual(
            run.metricsJSON,
            #"{"actionItemCount":1,"outputUTF8Bytes":16}"#)
        for privateText in ["private transcript", "private note", "SecretTerm", "private summary"] {
            XCTAssertFalse(run.configJSON.contains(privateText))
            XCTAssertFalse(run.metricsJSON?.contains(privateText) == true)
        }
    }

    func testTerminalFailureAndCancellationCarryNoInventedOutputMetrics() {
        let fixture = Fixture()

        let failed = fixture.attempt.finish(outcome: .failed, draft: nil)
        let cancelled = fixture.attempt.finish(outcome: .cancelled, draft: nil)

        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertNil(failed.metricsJSON)
        XCTAssertEqual(cancelled.outcome, .cancelled)
        XCTAssertNil(cancelled.metricsJSON)
        XCTAssertNotEqual(failed.id, cancelled.id)
    }
}

private struct Fixture {
    let meetingID = MeetingID()
    let startedAt = Date(timeIntervalSince1970: 100)
    let attempt: PostCaptureSummaryGenerationAttempt
    let draft: SummaryDraft

    init() {
        let meetingID = self.meetingID
        let speaker = Speaker(meetingID: meetingID, label: "S1")
        let request = SummaryRequest(
            meetingID: meetingID,
            segments: [TranscriptSegment(
                meetingID: meetingID,
                speakerID: speaker.id,
                channel: .system,
                text: "private transcript",
                startTime: 0,
                endTime: 1,
                isFinal: true)],
            speakers: [speaker],
            recipe: .general,
            targetLanguage: "es",
            glossary: ["SecretTerm"],
            contextItems: [ContextItem(
                meetingID: meetingID,
                kind: .note,
                content: "private note",
                timestamp: 0)])
        let job = ProcessingJob(
            id: ProcessingJobID(rawValue: UUID(
                uuidString: "31313131-3131-3131-3131-313131313131")!),
            meetingID: meetingID,
            kind: .summary,
            inputFingerprint: "summary-operation-fingerprint",
            state: .running,
            attempt: 2)
        let selection = PostCaptureSummaryProviderSelection(
            provider: ProviderStub(),
            providerID: "durable-provider",
            modelID: "durable-model",
            modelRevision: "pinned-revision")
        attempt = PostCaptureSummaryGenerationAttempt(
            job: job,
            request: request,
            selection: selection,
            sourceTranscriptRevision: 7,
            startedAt: startedAt)
        draft = SummaryDraft(
            meetingID: meetingID,
            recipeID: Recipe.general.id,
            language: "es",
            markdown: "private summary\n",
            actionItems: [ActionItem(text: "private action")],
            fingerprint: "material-fingerprint")
    }
}

private struct ProviderStub: SummaryProvider {
    func summarize(_ request: SummaryRequest) async throws -> SummaryDraft {
        preconditionFailure("metadata tests never invoke the provider")
    }
}
