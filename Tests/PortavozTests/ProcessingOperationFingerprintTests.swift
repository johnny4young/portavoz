import DiarizationKit
import Foundation
import IntelligenceKit
import PortavozCore
import TranscriptionKit
import XCTest

final class ProcessingOperationFingerprintTests: XCTestCase {
    private let meetingID = MeetingID(
        rawValue: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!)

    func testGenericFingerprintKeepsComponentBoundaries() {
        XCTAssertEqual(
            OperationFingerprint.make(version: "v1", components: ["ab", "c"]),
            OperationFingerprint.make(version: "v1", components: ["ab", "c"]))
        XCTAssertNotEqual(
            OperationFingerprint.make(version: "v1", components: ["ab", "c"]),
            OperationFingerprint.make(version: "v1", components: ["a", "bc"]))
    }

    func testDiarizationFingerprintIsStableAcrossSegmentOrder() throws {
        let first = segment(
            id: "22222222-2222-2222-2222-222222222222",
            text: "hola", language: "es", start: 0)
        let second = segment(
            id: "33333333-3333-3333-3333-333333333333",
            text: "hello", language: "en", start: 3)
        let asset = systemAsset()
        let voiceprint = Voiceprint(
            embedding: [0.1, -0.2], createdAt: Date(timeIntervalSince1970: 123))

        let forward = try XCTUnwrap(DiarizationOperationFingerprint.compute(
            meetingID: meetingID,
            transcriptRevision: 2,
            segments: [first, second],
            systemAsset: asset,
            voiceprint: voiceprint))
        let reversed = try XCTUnwrap(DiarizationOperationFingerprint.compute(
            meetingID: meetingID,
            transcriptRevision: 2,
            segments: [second, first],
            systemAsset: asset,
            voiceprint: voiceprint))

        XCTAssertEqual(forward, reversed)
        XCTAssertNotEqual(
            forward,
            DiarizationOperationFingerprint.compute(
                meetingID: meetingID,
                transcriptRevision: 2,
                segments: [segment(
                    id: "22222222-2222-2222-2222-222222222222",
                    text: "hello", language: "en", start: 0), second],
                systemAsset: asset,
                voiceprint: voiceprint))
        XCTAssertNotEqual(
            forward,
            DiarizationOperationFingerprint.compute(
                meetingID: meetingID,
                transcriptRevision: 3,
                segments: [first, second],
                systemAsset: asset,
                voiceprint: voiceprint))
    }

    func testDiarizationFingerprintRequiresFinalizedSystemEvidence() {
        var pending = systemAsset()
        pending.healthStatus = .pending
        XCTAssertNil(diarizationFingerprint(systemAsset: pending))

        var incomplete = systemAsset()
        incomplete.sha256 = nil
        XCTAssertNil(diarizationFingerprint(systemAsset: incomplete))

        var corrupt = systemAsset()
        corrupt.healthStatus = .corrupt
        corrupt.sha256 = nil
        corrupt.durationSeconds = nil
        XCTAssertNotNil(diarizationFingerprint(systemAsset: corrupt))
        XCTAssertNotNil(diarizationFingerprint(systemAsset: nil))
    }

    func testDiarizationRequestCarriesExactExecutionPolicy() throws {
        let segments = [segment(
            id: "22222222-2222-2222-2222-222222222222",
            text: "hola", language: "es", start: 0)]
        let request = try XCTUnwrap(DiarizationOperationFingerprint.request(
            meetingID: meetingID,
            transcriptRevision: 7,
            segments: segments,
            systemAsset: systemAsset(),
            voiceprint: nil))

        XCTAssertEqual(request.kind, .diarization)
        XCTAssertEqual(request.priority, 20)
        XCTAssertEqual(request.maxAttempts, 3)
        XCTAssertNil(request.notBefore)
        XCTAssertEqual(
            request.inputFingerprint,
            DiarizationOperationFingerprint.compute(
                meetingID: meetingID,
                transcriptRevision: 7,
                segments: segments,
                systemAsset: systemAsset(),
                voiceprint: nil))
    }

    func testSummaryOperationAddsLanguageAndRevisionToMaterialIdentity() {
        let spanish = summaryRequest(language: "es")
        let english = summaryRequest(language: "en")
        let base = SummaryOperationFingerprint.compute(
            request: spanish, providerID: "foundation-models", transcriptRevision: 4)

        XCTAssertEqual(
            base,
            SummaryOperationFingerprint.compute(
                request: spanish, providerID: "foundation-models", transcriptRevision: 4))
        XCTAssertNotEqual(
            base,
            SummaryOperationFingerprint.compute(
                request: english, providerID: "foundation-models", transcriptRevision: 4))
        XCTAssertNotEqual(
            base,
            SummaryOperationFingerprint.compute(
                request: spanish, providerID: "foundation-models", transcriptRevision: 5))
        XCTAssertNotEqual(
            base,
            SummaryOperationFingerprint.compute(
                request: spanish, providerID: "local/model", transcriptRevision: 4))
    }

    func testRefineFingerprintIsChannelOrderStableAndMaterialSensitive() throws {
        let system = RefineTranscriptionChannelEvidence(
            channel: .system,
            contentFingerprint: "system-sha")
        let microphone = RefineTranscriptionChannelEvidence(
            channel: .microphone,
            contentFingerprint: "microphone-sha")
        let base = try XCTUnwrap(RefineTranscriptionOperationFingerprint.compute(.init(
            meetingID: meetingID,
            sourceTranscriptRevision: 4,
            providerID: "whisperkit/coreml",
            modelID: "whisper-large-v3",
            modelRevision: "revision",
            languageHint: nil,
            vocabulary: ["Portavoz"],
            channels: [system, microphone])))

        XCTAssertEqual(
            base,
            RefineTranscriptionOperationFingerprint.compute(.init(
                meetingID: meetingID,
                sourceTranscriptRevision: 4,
                providerID: "whisperkit/coreml",
                modelID: "whisper-large-v3",
                modelRevision: "revision",
                languageHint: nil,
                vocabulary: ["Portavoz"],
                channels: [microphone, system])))
        XCTAssertNotEqual(
            base,
            RefineTranscriptionOperationFingerprint.compute(.init(
                meetingID: meetingID,
                sourceTranscriptRevision: 5,
                providerID: "whisperkit/coreml",
                modelID: "whisper-large-v3",
                modelRevision: "revision",
                languageHint: nil,
                vocabulary: ["Portavoz"],
                channels: [system, microphone])))
        XCTAssertNotEqual(
            base,
            RefineTranscriptionOperationFingerprint.compute(.init(
                meetingID: meetingID,
                sourceTranscriptRevision: 4,
                providerID: "whisperkit/coreml",
                modelID: "whisper-large-v3",
                modelRevision: "revision",
                languageHint: "es",
                vocabulary: ["Portavoz"],
                channels: [system, microphone])))
        XCTAssertNotEqual(
            refineFingerprint(modelRevision: nil, languageHint: nil, channels: [system]),
            refineFingerprint(
                modelRevision: "revision",
                languageHint: nil,
                channels: [system]))
        XCTAssertNotEqual(
            refineFingerprint(modelRevision: "revision", languageHint: nil, channels: [system]),
            refineFingerprint(
                modelRevision: "revision",
                languageHint: "automatic",
                channels: [system]))
    }

    func testRefineFingerprintRejectsMissingOrDuplicateChannelEvidence() {
        let system = RefineTranscriptionChannelEvidence(
            channel: .system,
            contentFingerprint: "system-sha")
        XCTAssertNil(refineFingerprint(channels: []))
        XCTAssertNil(refineFingerprint(channels: [
            system,
            RefineTranscriptionChannelEvidence(
                channel: .system,
                contentFingerprint: "other-sha"),
        ]))
        XCTAssertNil(refineFingerprint(channels: [
            RefineTranscriptionChannelEvidence(
                channel: .microphone,
                contentFingerprint: " "),
        ]))
        XCTAssertNil(refineFingerprint(modelRevision: " ", channels: [system]))
        XCTAssertNil(refineFingerprint(languageHint: " ", channels: [system]))
    }

    private func segment(
        id: String,
        text: String,
        language: String,
        start: TimeInterval
    ) -> TranscriptSegment {
        TranscriptSegment(
            id: UUID(uuidString: id)!,
            meetingID: meetingID,
            channel: .system,
            text: text,
            language: language,
            startTime: start,
            endTime: start + 2,
            confidence: 0.9,
            isFinal: true)
    }

    private func systemAsset() -> AudioAsset {
        AudioAsset(
            id: AudioAssetID(
                rawValue: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!),
            meetingID: meetingID,
            channel: .system,
            role: .capture,
            relativePath: "recording/system.caf",
            durationSeconds: 5,
            sha256: "audio-sha",
            healthStatus: .healthy)
    }

    private func diarizationFingerprint(systemAsset: AudioAsset?) -> String? {
        DiarizationOperationFingerprint.compute(
            meetingID: meetingID,
            transcriptRevision: 0,
            segments: [segment(
                id: "22222222-2222-2222-2222-222222222222",
                text: "hola", language: "es", start: 0)],
            systemAsset: systemAsset,
            voiceprint: nil)
    }

    private func summaryRequest(language: String) -> SummaryRequest {
        SummaryRequest(
            meetingID: meetingID,
            segments: [segment(
                id: "22222222-2222-2222-2222-222222222222",
                text: "hola", language: "es", start: 0)],
            speakers: [],
            recipe: .general,
            targetLanguage: language,
            glossary: ["Portavoz"])
    }

    private func refineFingerprint(
        modelRevision: String? = "revision",
        languageHint: String? = nil,
        channels: [RefineTranscriptionChannelEvidence]
    ) -> String? {
        RefineTranscriptionOperationFingerprint.compute(.init(
            meetingID: meetingID,
            sourceTranscriptRevision: 4,
            providerID: "whisperkit/coreml",
            modelID: "whisper-large-v3",
            modelRevision: modelRevision,
            languageHint: languageHint,
            vocabulary: [],
            channels: channels))
    }
}
