import Foundation
import PortavozCore
import TranscriptionKit
import XCTest

final class InitialTranscriptionOperationFingerprintTests: XCTestCase {
    private let meetingID = MeetingID(rawValue: UUID(
        uuidString: "73737373-7373-7373-7373-737373737373")!)
    private let now = Date(timeIntervalSince1970: 1_783_699_200)

    func testRequestIsDeterministicAcrossAssetOrder() throws {
        let system = asset(.system, digest: String(repeating: "a", count: 64))
        let microphone = asset(.microphone, digest: String(repeating: "b", count: 64))

        let forward = InitialTranscriptionOperationFingerprint.request(
            meetingID: meetingID,
            transcriptRevision: 0,
            assets: [system, microphone])
        let reversed = InitialTranscriptionOperationFingerprint.request(
            meetingID: meetingID,
            transcriptRevision: 0,
            assets: [microphone, system])

        let request = try XCTUnwrap(forward)
        XCTAssertEqual(request, reversed)
        XCTAssertEqual(request.kind, .transcription)
        XCTAssertEqual(request.priority, 30)
        XCTAssertEqual(request.maxAttempts, 3)
    }

    func testFingerprintChangesWithRevisionOrAudioBytes() throws {
        let original = asset(.system, digest: String(repeating: "a", count: 64))
        let changed = asset(.system, digest: String(repeating: "c", count: 64))

        let revisionZero = try XCTUnwrap(InitialTranscriptionOperationFingerprint.compute(
            meetingID: meetingID,
            transcriptRevision: 0,
            assets: [original]))
        let revisionOne = try XCTUnwrap(InitialTranscriptionOperationFingerprint.compute(
            meetingID: meetingID,
            transcriptRevision: 1,
            assets: [original]))
        let changedAudio = try XCTUnwrap(InitialTranscriptionOperationFingerprint.compute(
            meetingID: meetingID,
            transcriptRevision: 0,
            assets: [changed]))

        XCTAssertNotEqual(revisionZero, revisionOne)
        XCTAssertNotEqual(revisionZero, changedAudio)
    }

    func testPendingMissingOrOnlySilentAudioCannotAdmitRecovery() {
        var pending = asset(.system, digest: String(repeating: "a", count: 64))
        pending.healthStatus = .pending
        var missing = pending
        missing.healthStatus = .missing
        var silent = pending
        silent.healthStatus = .silent

        for assets in [[pending], [missing], [silent]] {
            XCTAssertNil(InitialTranscriptionOperationFingerprint.request(
                meetingID: meetingID,
                transcriptRevision: 0,
                assets: assets))
        }
    }

    private func asset(_ channel: AudioChannel, digest: String) -> AudioAsset {
        AudioAsset(
            meetingID: meetingID,
            channel: channel,
            role: .capture,
            relativePath: "Audio/fixture/\(channel.rawValue).caf",
            container: "caf",
            codec: "pcm-s16le",
            sampleRate: 48_000,
            channelCount: 1,
            durationSeconds: 60,
            byteCount: 5_760_128,
            sha256: digest,
            healthStatus: .healthy,
            createdAt: now)
    }
}
