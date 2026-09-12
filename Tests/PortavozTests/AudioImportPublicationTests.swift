import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class AudioImportPublicationTests: XCTestCase {
    func testCopyPublicationRetiresBookmarkAndCompletionPreservesAnEditedTitle() async throws {
        let fixture = try await ImportPublicationFixture.make()
        let published = try await fixture.publishCopy()
        XCTAssertNil(published.sourceBookmark)
        XCTAssertEqual(published.copiedAudioDirectory, fixture.directory)
        let repeated = try await fixture.publishCopy()
        XCTAssertEqual(repeated, published)
        let key = fixture.request.meetingID.rawValue.uuidString
        try await fixture.store.database.write { database in
            try database.execute(sql: "UPDATE meeting SET title = 'Edited — editado' WHERE id = ?", arguments: [key])
            let data = try Data.fetchOne(database, sql: "SELECT payload FROM audioImportInput")
            XCTAssertFalse(String(decoding: try XCTUnwrap(data), as: UTF8.self)
                .contains(Data("synthetic source capability".utf8).base64EncodedString()))
        }
        let committed = try await fixture.complete()
        XCTAssertEqual(committed.completedJob.state, .succeeded)
        XCTAssertEqual(committed.artifactVersion, 1)
        let detail = try await fixture.store.detail(fixture.request.meetingID)
        XCTAssertEqual(detail?.meeting.title, "Edited — editado")
        XCTAssertEqual(detail?.meeting.lifecycleState, .ready)
        XCTAssertEqual(detail?.meeting.audioDirectory, fixture.directory)
        XCTAssertEqual(detail?.segments.map(\.text), ["Don’t send 2 — no envíes 2"])
        do {
            _ = try await fixture.complete()
            XCTFail("A completed lease cannot publish another transcript")
        } catch {}
    }

    func testCompletionBeforeCopyAndWithWrongDigestNeverPublishes() async throws {
        let fixture = try await ImportPublicationFixture.make()
        do {
            _ = try await fixture.complete()
            XCTFail("An external capability is not durable owned audio")
        } catch {}
        _ = try await fixture.publishCopy()
        do {
            _ = try await fixture.complete(digest: String(repeating: "f", count: 64))
            XCTFail("The transcript must identify the published copy")
        } catch {}
        let detail = try await fixture.store.detail(fixture.request.meetingID)
        XCTAssertTrue(detail?.segments.isEmpty == true)
        XCTAssertEqual(detail?.meeting.lifecycleState, .processing)
    }

    func testCrossMeetingOrTraversalCopyNeverRetiresTheSource() async throws {
        let fixture = try await ImportPublicationFixture.make()
        for path in ["/tmp/audio", "Audio/../Imports/\(UUID())", "Audio/\(UUID())/Imports/\(UUID())",
                     "Audio/\(fixture.request.meetingID.rawValue)/Imports/\(UUID())",
                     "\(fixture.directory)/", "\(fixture.directory)/../other"] {
            do {
                _ = try await fixture.store.publishAudioImportCopy(
                    for: fixture.job.id, owner: "owner", relativeDirectory: path,
                    digest: fixture.digest, at: fixture.now)
                XCTFail("Owned audio cannot escape the exact admitted meeting")
            } catch {}
        }
        let retained = try await fixture.store.audioImportInput(for: fixture.job.id, owner: "owner", at: fixture.now)
        XCTAssertEqual(retained, fixture.request)
        let detail = try await fixture.store.detail(fixture.request.meetingID)
        XCTAssertEqual(detail?.meeting.audioDirectory, fixture.request.copyDirectory)
    }

    func testCancelledOrExpiredOwnerCannotPublishCopyOrTranscript() async throws {
        for cancel in [false, true] {
            let fixture = try await ImportPublicationFixture.make()
            _ = try await fixture.publishCopy()
            if cancel {
                _ = try await fixture.store.cancelAudioImport(for: fixture.request.meetingID, at: fixture.now)
            }
            let time = cancel ? fixture.now : fixture.now.addingTimeInterval(30)
            do {
                _ = try await fixture.publishCopy(at: time)
                XCTFail("The exact lease boundary must reject publication")
            } catch {}
            do {
                _ = try await fixture.complete(at: time)
                XCTFail("A late worker cannot publish accepted content")
            } catch {}
            let detail = try await fixture.store.detail(fixture.request.meetingID)
            XCTAssertTrue(detail?.segments.isEmpty == true)
            XCTAssertEqual(detail?.meeting.audioDirectory, fixture.directory)
        }
    }

    func testFailedChildWriteRollsBackRevisionAndJobSuccessButKeepsOwnedAudio() async throws {
        let fixture = try await ImportPublicationFixture.make()
        _ = try await fixture.publishCopy()
        try await fixture.store.database.write { database in
            try database.execute(sql: """
                CREATE TRIGGER reject_import_segment BEFORE INSERT ON segment
                BEGIN SELECT RAISE(ABORT, 'synthetic write failure'); END
                """)
        }
        do {
            _ = try await fixture.complete()
            XCTFail("Child failure must roll back the complete aggregate transaction")
        } catch {}
        let detail = try await fixture.store.detail(fixture.request.meetingID)
        let jobs = try await fixture.store.processingJobs(for: fixture.request.meetingID)
        XCTAssertTrue(detail?.segments.isEmpty == true)
        XCTAssertTrue(detail?.speakers.isEmpty == true)
        XCTAssertEqual(detail?.meeting.transcriptRevision, 0)
        XCTAssertEqual(detail?.meeting.audioDirectory, fixture.directory)
        XCTAssertEqual(jobs.first?.state, .running)
        try await fixture.store.database.write { database in
            try database.execute(sql: "DROP TRIGGER reject_import_segment")
        }
        let recovered = try await fixture.complete()
        XCTAssertEqual(recovered.completedJob.state, .succeeded)
    }

    func testSilentImportRetainsAudioWithoutInventingTranscript() async throws {
        let fixture = try await ImportPublicationFixture.make()
        _ = try await fixture.publishCopy()
        let result = try await fixture.complete(segments: [])
        XCTAssertEqual(result.completedJob.state, .succeeded)
        let detail = try await fixture.store.detail(fixture.request.meetingID)
        XCTAssertTrue(detail?.segments.isEmpty == true)
        XCTAssertEqual(detail?.meeting.audioDirectory, fixture.directory)
    }

    func testPublishedCopyCannotBeReplacedUnderTheSameLease() async throws {
        let fixture = try await ImportPublicationFixture.make()
        _ = try await fixture.publishCopy()
        do {
            _ = try await fixture.store.publishAudioImportCopy(
                for: fixture.job.id, owner: "owner",
                relativeDirectory: "Audio/\(fixture.request.meetingID.rawValue)/Imports/\(UUID())",
                digest: fixture.digest, at: fixture.now)
            XCTFail("A second copy cannot overwrite the durable first publication")
        } catch {}
        let input = try await fixture.store.audioImportInput(for: fixture.job.id, owner: "owner", at: fixture.now)
        XCTAssertEqual(input.copiedAudioDirectory, fixture.directory)
    }

    func testExplicitRetryKeepsIdentityAndCopyButNeverStealsThePreviousOwner() async throws {
        let fixture = try await ImportPublicationFixture.make()
        _ = try await fixture.publishCopy()
        let stillRunning = try await fixture.store.retryAudioImport(for: fixture.request.meetingID, at: fixture.now)
        XCTAssertEqual(stillRunning.leaseOwner, "owner")
        XCTAssertEqual(stillRunning.attempt, 1)
        _ = try await fixture.store.cancelAudioImport(for: fixture.request.meetingID, at: fixture.now)
        let retried = try await fixture.store.retryAudioImport(for: fixture.request.meetingID, at: fixture.now)
        XCTAssertEqual(retried.id, fixture.job.id)
        XCTAssertEqual(retried.state, .pending)
        _ = try await fixture.store.claimNextProcessingJob(
            kinds: [.audioImport], owner: "new-owner", leaseDuration: 30, at: fixture.now)
        do {
            _ = try await fixture.complete()
            XCTFail("Retry cannot restore a stale worker's publication authority")
        } catch {}
        let resumed = try await fixture.store.audioImportInput(for: fixture.job.id, owner: "new-owner", at: fixture.now)
        XCTAssertNil(resumed.sourceBookmark)
        XCTAssertEqual(resumed.copiedAudioDirectory, fixture.directory)
    }

    func testRetryCannotReplayCompletedImport() async throws {
        let fixture = try await ImportPublicationFixture.make()
        _ = try await fixture.publishCopy()
        let committed = try await fixture.complete()
        let retried = try await fixture.store.retryAudioImport(for: fixture.request.meetingID, at: fixture.now)
        XCTAssertEqual(retried, committed.completedJob)
        let next = try await fixture.store.claimNextProcessingJob(
            kinds: [.audioImport], owner: "new-owner", leaseDuration: 30, at: fixture.now)
        XCTAssertNil(next)
    }

    func testReopenAfterPublishedCopyReclaimsExpiredWorkWithoutExternalCapability() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("library.sqlite")
        let originalJob: ProcessingJob
        let published: AudioImportRequest
        let later: Date
        do {
            let fixture = try await ImportPublicationFixture.make(databaseURL: databaseURL)
            originalJob = fixture.job
            published = try await fixture.publishCopy()
            later = fixture.now.addingTimeInterval(31)
        }
        let reopened = try MeetingStore(databaseURL: databaseURL)
        let reclaimed = try await reopened.claimNextProcessingJob(
            kinds: [.audioImport], owner: "relaunch", leaseDuration: 30, at: later)
        XCTAssertEqual(reclaimed?.id, originalJob.id)
        XCTAssertEqual(reclaimed?.attempt, 2)
        let input = try await reopened.audioImportInput(for: originalJob.id, owner: "relaunch", at: later)
        XCTAssertEqual(input, published)
        XCTAssertNil(input.sourceBookmark)
        let detail = try await reopened.detail(input.meetingID)
        XCTAssertEqual(detail?.meeting.audioDirectory, input.copiedAudioDirectory)
    }
}

private struct ImportPublicationFixture {
    let store: MeetingStore
    let request: AudioImportRequest
    let job: ProcessingJob
    let now: Date
    let directory: String
    let digest = String(repeating: "a", count: 64)

    static func make(databaseURL: URL? = nil) async throws -> Self {
        let store = try databaseURL.map { try MeetingStore(databaseURL: $0) } ?? MeetingStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_789_200_000)
        let request = AudioImportRequest(
            title: "Synthetic — sintética", fileExtension: "wav", sourceByteCount: 240,
            sourceModifiedAt: now, sourceBookmark: Data("synthetic source capability".utf8),
            preferences: .init(transcriptLanguage: .automatic, summaryLanguage: .followSpokenLanguage,
                               summaryFallbackLanguage: .english, vocabulary: []))
        _ = try await store.enqueueAudioImports([request], at: now)
        let claimed = try await store.claimNextProcessingJob(
            kinds: [.audioImport], owner: "owner", leaseDuration: 30, at: now)
        return Self(store: store, request: request, job: try XCTUnwrap(claimed), now: now,
                    directory: request.copyDirectory)
    }

    func publishCopy(at timestamp: Date? = nil) async throws -> AudioImportRequest {
        try await store.publishAudioImportCopy(for: job.id, owner: "owner", relativeDirectory: directory,
                                              digest: digest, at: timestamp ?? now)
    }

    func complete(
        digest: String? = nil, segments: [TranscriptSegment]? = nil, at timestamp: Date? = nil
    ) async throws -> ProcessingArtifactCommit {
        let artifact = TranscriptionArtifact(
            meetingID: request.meetingID, inputFingerprint: job.inputFingerprint, sourceTranscriptRevision: 0,
            language: nil, speakers: [], segments: segments ?? [
                TranscriptSegment(meetingID: request.meetingID, channel: .system,
                                  text: "Don’t send 2 — no envíes 2", startTime: 0, endTime: 1)
            ])
        return try await store.completeAudioImport(job.id, owner: "owner", artifact: artifact,
                                                   audioDuration: 1, audioDigest: digest ?? self.digest,
                                                   at: timestamp ?? now)
    }
}
