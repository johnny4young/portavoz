import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class SupportDiagnosticsTests: XCTestCase {
    func testExportIsUsefulAndRedactsEverySensitiveCorpus() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID(rawValue: UUID(
            uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        let meeting = Meeting(
            id: meetingID,
            title: "SECRET customer roadmap",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            endedAt: Date(timeIntervalSince1970: 1_700_000_600),
            audioDirectory: "Audio/SECRET-local-folder",
            lifecycleState: .captured)
        try await store.save(meeting)
        let speaker = Speaker(
            meetingID: meetingID,
            label: "S1",
            displayName: "SECRET participant")
        try await store.save([speaker])
        try await store.save([TranscriptSegment(
            meetingID: meetingID,
            speakerID: speaker.id,
            channel: .system,
            text: "SECRET transcript sentence",
            startTime: 0,
            endTime: 4,
            isFinal: true)])
        _ = try await store.saveSummary(SummaryDraft(
            meetingID: meetingID,
            recipeID: Recipe.general.id,
            language: "en",
            markdown: "SECRET generated output",
            actionItems: [ActionItem(text: "SECRET action item")]))

        _ = try await store.enqueueProcessingJobs(
            for: meetingID,
            requests: [ProcessingJobRequest(
                kind: .transcription,
                inputFingerprint: "SECRET raw processing fingerprint",
                maxAttempts: 1)])
        let claimedValue = try await store.claimNextProcessingJob(
            kinds: [.transcription],
            owner: "diagnostics-test",
            leaseDuration: 60)
        let claimed = try XCTUnwrap(claimedValue)
        _ = try await store.failProcessingJob(
            claimed.id,
            owner: "diagnostics-test",
            failure: ProcessingJobFailure(
                code: "processing.transcription.failed",
                message: "SECRET error /Users/person/recording.caf https://token@example.com"))

        try await store.saveGenerationRun(GenerationRun(
            meetingID: meetingID,
            kind: .summary,
            providerID: "foundation-models",
            modelID: "local-model",
            inputFingerprint: "SECRET raw generation fingerprint",
            configJSON: "{\"prompt\":\"SECRET prompt\",\"url\":\"https://secret.example/path\"}",
            outputLanguage: "en",
            startedAt: Date(timeIntervalSince1970: 1_700_000_100),
            finishedAt: Date(timeIntervalSince1970: 1_700_000_101),
            outcome: .failed,
            metricsJSON: "{\"output\":\"SECRET metrics payload\"}"))
        try await store.recordDataEgressEvent(DataEgressEvent(
            meetingID: meetingID,
            operation: .summaryGeneration,
            destinationScope: .remote,
            destinationHost: "api.example.com",
            dataClassification: .meetingSummaryMaterial,
            consentSource: .summaryEngineSettings,
            providerID: "api.example.com",
            modelID: "support-model",
            attemptedAt: Date(timeIntervalSince1970: 1_700_000_102)))

        let data = try await ExportSupportDiagnostics(store: store).execute(
            ExportSupportDiagnosticsRequest(
                environment: SupportDiagnosticsEnvironment(
                    appVersion: "0.7.0",
                    buildVersion: "700",
                    operatingSystem: "macOS 15.6",
                    models: [SupportModelReadiness(
                        capability: "whisper-turbo",
                        state: .installed)]),
                generatedAt: Date(timeIntervalSince1970: 1_700_000_200)))
        let text = String(decoding: data, as: UTF8.self)
        let forbidden = [
            meetingID.rawValue.uuidString,
            "SECRET customer roadmap",
            "SECRET-local-folder",
            "SECRET participant",
            "SECRET transcript sentence",
            "SECRET generated output",
            "SECRET action item",
            "SECRET raw processing fingerprint",
            "SECRET raw generation fingerprint",
            "SECRET error",
            "/Users/person/recording.caf",
            "https://token@example.com",
            "SECRET prompt",
            "https://secret.example/path",
            "SECRET metrics payload"
        ]
        for value in forbidden {
            XCTAssertFalse(text.contains(value), "diagnostics leaked: \(value)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(SupportDiagnosticsReport.self, from: data)
        XCTAssertEqual(report.formatVersion, 1)
        XCTAssertEqual(report.storage.schemaVersion, 14)
        XCTAssertEqual(report.storage.meetingCount, 1)
        XCTAssertTrue(report.meetings[0].reference.hasPrefix("meeting-"))
        XCTAssertEqual(report.meetings[0].lifecycleState, "needsAttention")
        XCTAssertEqual(
            report.meetings[0].lastProcessingError,
            "processing.transcription.failed")
        XCTAssertEqual(report.meetings[0].processingJobs[0].state, "failed")
        XCTAssertEqual(report.meetings[0].generationRuns[0].providerID, "foundation-models")
        XCTAssertEqual(
            report.meetings[0].privacyReceipt.events[0].destinationHost,
            "api.example.com")
        XCTAssertEqual(
            report.meetings[0].privacyReceipt.status,
            "remote-transfer-attempted")
    }
}
