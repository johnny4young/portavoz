import ApplicationKit
import Foundation
import PortavozCore
@testable import StorageKit
import XCTest

final class SupportDiagnosticsTests: XCTestCase {
    func testSampleRateProjectionRejectsNonsensicalValues() {
        XCTAssertNil(supportPositiveFinite(nil))
        XCTAssertNil(supportPositiveFinite(-48_000))
        XCTAssertNil(supportPositiveFinite(0))
        XCTAssertNil(supportPositiveFinite(.nan))
        XCTAssertNil(supportPositiveFinite(.infinity))
        XCTAssertEqual(supportPositiveFinite(48_000), 48_000)
    }

    func testExportIsUsefulAndRedactsEverySensitiveCorpus() async throws {
        let store = try MeetingStore.inMemory()
        let meetingID = MeetingID(rawValue: UUID(
            uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!)
        var meeting = Meeting(
            id: meetingID,
            title: "SECRET customer roadmap",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            audioDirectory: "Audio/SECRET-local-folder",
            lifecycleState: .recording)
        let reservations = [AudioChannel.microphone, .system].map { channel in
            AudioAsset.pendingCapture(
                meetingID: meetingID,
                channel: channel,
                relativePath: AudioCapturePath.stagingRelativePath(
                    directory: meeting.audioDirectory!, channel: channel),
                at: meeting.startedAt)
        }
        try await store.beginRecording(meeting, assets: reservations)
        let speaker = Speaker(
            meetingID: meetingID,
            label: "S1",
            displayName: "SECRET participant")
        let segment = TranscriptSegment(
            meetingID: meetingID,
            speakerID: speaker.id,
            channel: .system,
            text: "SECRET transcript sentence",
            startTime: 0,
            endTime: 4,
            isFinal: true)
        let finalized = reservations.map { reservation -> AudioAsset in
            var asset = reservation
            asset.relativePath = AudioCapturePath.publishedRelativePath(
                directory: meeting.audioDirectory!, channel: reservation.channel)
            asset.container = "caf"
            asset.codec = "pcm-s16le"
            asset.sampleRate = 48_000
            asset.channelCount = 1
            asset.durationSeconds = reservation.channel == .microphone ? 600 : 200
            asset.byteCount = reservation.channel == .microphone ? 57_600_128 : 19_200_128
            asset.sha256 = String(repeating: reservation.channel == .microphone ? "a" : "b", count: 64)
            asset.healthStatus = .healthy
            asset.peakDBFS = -6
            asset.rmsDBFS = -24
            asset.updatedAt = meeting.startedAt.addingTimeInterval(600)
            return asset
        }
        meeting.endedAt = Date(timeIntervalSince1970: 1_700_000_600)
        meeting.lifecycleState = .captured
        try await store.installCapturedSnapshot(CapturedMeetingSnapshot(
            meeting: meeting,
            assets: finalized,
            speakers: [speaker],
            segments: [segment],
            contextItems: [],
            companionCards: []))
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
        let pendingSync = try await store.pendingMeetingSyncChanges()
        let syncChange = try XCTUnwrap(pendingSync.first { $0.meetingID == meetingID })
        try await store.acknowledgeMeetingSync(syncChange)

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
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64),
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
        XCTAssertEqual(report.formatVersion, 2)
        XCTAssertEqual(report.storage.schemaVersion, 14)
        XCTAssertEqual(report.storage.meetingCount, 1)
        XCTAssertTrue(report.meetings[0].reference.hasPrefix("meeting-"))
        XCTAssertEqual(report.meetings[0].lifecycleState, "needsAttention")
        XCTAssertEqual(report.meetings[0].audioAssets.map(\.channel), ["microphone", "system"])
        XCTAssertEqual(report.meetings[0].audioAssets.map(\.durationSeconds), [600, 200])
        XCTAssertEqual(report.meetings[0].audioAssets.map(\.healthStatus), ["healthy", "healthy"])
        XCTAssertEqual(report.meetings[0].transcript.segmentCount, 1)
        XCTAssertEqual(report.meetings[0].transcript.microphoneSegmentCount, 0)
        XCTAssertEqual(report.meetings[0].transcript.systemSegmentCount, 1)
        XCTAssertEqual(report.meetings[0].transcript.attributedSegmentCount, 1)
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
        XCTAssertEqual(
            report.meetings[0].privacyReceipt.syncDisclosure,
            "acknowledged-by-private-cloud")
    }

    func testAcknowledgedPrivateCloudCopyScopesTheAllLocalStatus() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = Meeting(title: "Private planning", startedAt: Date())
        try await store.save(meeting)
        let pending = try await store.pendingMeetingSyncChanges()
        let change = try XCTUnwrap(pending.first { $0.meetingID == meeting.id })
        try await store.acknowledgeMeetingSync(change)

        let data = try await ExportSupportDiagnostics(store: store).execute(
            ExportSupportDiagnosticsRequest(
                environment: SupportDiagnosticsEnvironment(
                    appVersion: "0.7.0",
                    buildVersion: "700",
                    operatingSystem: "macOS 26",
                    models: [])))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(SupportDiagnosticsReport.self, from: data)

        XCTAssertEqual(
            report.meetings[0].privacyReceipt.status,
            "all-tracked-processing-stayed-on-device")
        XCTAssertEqual(
            report.meetings[0].privacyReceipt.syncDisclosure,
            "acknowledged-by-private-cloud")
    }
}
