import Foundation
import GRDB
import PortavozCore
import XCTest

@testable import StorageKit

final class RecordingPersistenceTests: XCTestCase {
    private func shell(
        id: MeetingID = MeetingID(),
        directory: String? = nil
    ) -> Meeting {
        Meeting(
            id: id,
            title: "Durable recording",
            startedAt: Date(timeIntervalSince1970: 1_783_695_600),
            audioDirectory: directory ?? "Audio/\(id.rawValue.uuidString)",
            lifecycleState: .recording)
    }

    private func assets(for meeting: Meeting, channels: [AudioChannel]) -> [AudioAsset] {
        channels.map { channel in
            AudioAsset.pendingCapture(
                meetingID: meeting.id,
                channel: channel,
                relativePath: AudioCapturePath.stagingRelativePath(
                    directory: meeting.audioDirectory!, channel: channel),
                at: meeting.startedAt)
        }
    }

    private func published(_ reservation: AudioAsset) -> AudioAsset {
        var asset = reservation
        let directory = reservation.relativePath
            .split(separator: "/").dropLast().joined(separator: "/")
        asset.relativePath = AudioCapturePath.publishedRelativePath(
            directory: directory, channel: asset.channel)
        asset.container = "caf"
        asset.codec = "pcm-s16le"
        asset.sampleRate = 48_000
        asset.channelCount = 1
        asset.durationSeconds = 2
        asset.byteCount = 192_128
        asset.sha256 = String(repeating: "a", count: 64)
        asset.healthStatus = .healthy
        asset.peakDBFS = -6
        asset.rmsDBFS = -18
        asset.updatedAt = asset.createdAt.addingTimeInterval(2)
        return asset
    }

    private func assertReservationRejected(
        by store: MeetingStore,
        meeting: Meeting,
        assets: [AudioAsset],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        do {
            try await store.beginRecording(meeting, assets: assets)
            XCTFail("invalid reservation was persisted", file: file, line: line)
        } catch {
            XCTAssertTrue(error is StorageError, file: file, line: line)
        }
        let detail = try await store.detail(meeting.id)
        XCTAssertNil(detail, file: file, line: line)
    }

    func testBeginRecordingAtomicallyPersistsShellAndPendingAssets() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = shell()
        let reserved = assets(for: meeting, channels: [.microphone, .system])

        try await store.beginRecording(meeting, assets: reserved)

        let storedDetail = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(storedDetail)
        XCTAssertEqual(detail.meeting.lifecycleState, .recording)
        XCTAssertNil(detail.meeting.endedAt)
        XCTAssertEqual(detail.meeting.audioDirectory, meeting.audioDirectory)
        let persisted = try await store.audioAssets(for: meeting.id)
        XCTAssertEqual(persisted.map(\.channel), [.microphone, .system])
        XCTAssertTrue(persisted.allSatisfy { $0.role == .capture })
        XCTAssertTrue(persisted.allSatisfy { $0.healthStatus == .pending })
        XCTAssertTrue(persisted.allSatisfy { $0.container == nil && $0.sha256 == nil })

        var corrupt = AudioAssetRecord(reserved[0])
        corrupt.channel = "corrupt-channel"
        XCTAssertThrowsError(try corrupt.asset) { error in
            guard case StorageError.invalidPersistedValue(
                table: "audioAsset", column: "channel", value: "corrupt-channel") = error
            else { return XCTFail("wrong error: \(error)") }
        }
        corrupt.channel = AudioChannel.microphone.rawValue
        corrupt.healthStatus = "corrupt-health"
        XCTAssertThrowsError(try corrupt.asset) { error in
            guard case StorageError.invalidPersistedValue(
                table: "audioAsset", column: "healthStatus", value: "corrupt-health") = error
            else { return XCTFail("wrong error: \(error)") }
        }
        corrupt.healthStatus = AudioAssetHealthStatus.pending.rawValue
        corrupt.relativePath = "/tmp/microphone.caf"
        XCTAssertThrowsError(try corrupt.asset) { error in
            guard case StorageError.absolutePathRejected = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testBeginRecordingRollsBackShellWhenAnAssetConflicts() async throws {
        let store = try MeetingStore.inMemory()
        let first = shell(directory: "Audio/shared-reservation")
        try await store.beginRecording(
            first, assets: assets(for: first, channels: [.microphone]))

        let second = shell(directory: "Audio/shared-reservation")
        do {
            try await store.beginRecording(
                second, assets: self.assets(for: second, channels: [.microphone]))
            XCTFail("a reserved path cannot belong to two recordings")
        } catch {
            XCTAssertTrue(error is DatabaseError, "wrong error: \(error)")
        }

        let secondDetail = try await store.detail(second.id)
        let meetings = try await store.meetings()
        let firstAssets = try await store.audioAssets(for: first.id)
        XCTAssertNil(secondDetail)
        XCTAssertEqual(meetings.map(\.id), [first.id])
        XCTAssertEqual(firstAssets.count, 1)
        try await store.database.read { db in
            XCTAssertTrue(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
        }
    }

    func testDiscardUnstartedRecordingIsLimitedToEmptyRecordingShells() async throws {
        let store = try MeetingStore.inMemory()
        let disposable = shell()
        try await store.beginRecording(
            disposable, assets: assets(for: disposable, channels: [.microphone]))

        let discarded = try await store.discardUnstartedRecording(disposable.id)
        let discardedDetail = try await store.detail(disposable.id)
        let discardedAssets = try await store.audioAssets(for: disposable.id)
        let discardedAgain = try await store.discardUnstartedRecording(disposable.id)
        XCTAssertTrue(discarded)
        XCTAssertNil(discardedDetail)
        XCTAssertTrue(discardedAssets.isEmpty)
        XCTAssertFalse(discardedAgain)

        let protected = shell()
        try await store.beginRecording(
            protected, assets: assets(for: protected, channels: [.microphone]))
        try await store.save([
            TranscriptSegment(
                meetingID: protected.id,
                channel: .microphone,
                text: "This captured content makes the shell a user meeting.",
                startTime: 0,
                endTime: 1,
                isFinal: true)
        ])
        do {
            _ = try await store.discardUnstartedRecording(protected.id)
            XCTFail("a shell with transcript content must be preserved")
        } catch {
            guard case StorageError.invalidRecordingReservation = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let protectedDetail = try await store.detail(protected.id)
        XCTAssertNotNil(protectedDetail)

        var invalid = shell()
        invalid.lifecycleState = .ready
        do {
            try await store.beginRecording(
                invalid, assets: self.assets(for: invalid, channels: [.microphone]))
            XCTFail("only recording lifecycle shells can be reserved")
        } catch {
            guard case StorageError.invalidRecordingReservation = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        let invalidDetail = try await store.detail(invalid.id)
        XCTAssertNil(invalidDetail)
    }

    func testBeginRecordingRejectsInvalidReservationShapesBeforeWriting() async throws {
        let store = try MeetingStore.inMemory()

        let missingAssets = shell()
        try await assertReservationRejected(
            by: store, meeting: missingAssets, assets: [])

        let traversal = shell(directory: "Audio/../escape")
        try await assertReservationRejected(
            by: store,
            meeting: traversal,
            assets: assets(for: traversal, channels: [.microphone]))

        let duplicateChannel = shell()
        let duplicateAssets = assets(
            for: duplicateChannel, channels: [.microphone, .microphone])
        try await assertReservationRejected(
            by: store, meeting: duplicateChannel, assets: duplicateAssets)

        let wrongOwner = shell()
        let anotherMeeting = shell()
        try await assertReservationRejected(
            by: store,
            meeting: wrongOwner,
            assets: assets(for: anotherMeeting, channels: [.microphone]))

        let wrongPath = shell()
        var mismatchedPath = assets(for: wrongPath, channels: [.microphone])
        mismatchedPath[0].relativePath = "Audio/somewhere-else/microphone.caf"
        try await assertReservationRejected(
            by: store, meeting: wrongPath, assets: mismatchedPath)

        let finalized = shell()
        var finalizedAssets = assets(for: finalized, channels: [.microphone])
        finalizedAssets[0].healthStatus = .healthy
        try await assertReservationRejected(
            by: store, meeting: finalized, assets: finalizedAssets)

        let prematureMetadata = shell()
        var metadataAssets = assets(for: prematureMetadata, channels: [.microphone])
        metadataAssets[0].container = "caf"
        try await assertReservationRejected(
            by: store, meeting: prematureMetadata, assets: metadataAssets)

        let derived = shell()
        var derivedAssets = assets(for: derived, channels: [.microphone])
        derivedAssets[0].role = AudioAssetRole(rawValue: "compressed")
        try await assertReservationRejected(
            by: store, meeting: derived, assets: derivedAssets)

        var preclassified = shell()
        preclassified.language = "en"
        try await assertReservationRejected(
            by: store,
            meeting: preclassified,
            assets: assets(for: preclassified, channels: [.microphone]))

        let persistedMeetings = try await store.meetings()
        XCTAssertTrue(persistedMeetings.isEmpty)
    }

    func testCapturedSnapshotInstallsFinalAssetsAndLiveContentAtomically() async throws {
        let store = try MeetingStore.inMemory()
        var meeting = shell()
        let reservations = assets(for: meeting, channels: [.microphone, .system])
        try await store.beginRecording(meeting, assets: reservations)

        var finalized = [published(reservations[0]), reservations[1]]
        finalized[1].healthStatus = .missing
        finalized[1].updatedAt = finalized[1].createdAt.addingTimeInterval(2)
        let speaker = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .microphone,
            text: "The live transcript survives later processing.",
            startTime: 0,
            endTime: 2,
            isFinal: true)
        let note = ContextItem(
            meetingID: meeting.id, kind: .note, content: "Follow up", timestamp: 1)
        let card = CompanionCard(
            question: "What changed?",
            answer: "The captured snapshot is atomic.",
            kind: .context,
            source: "on-device",
            askedAt: 1.5)
        let successfulRun = GenerationRun(
            meetingID: meeting.id,
            kind: .companion,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: String(repeating: "c", count: 64),
            configJSON: #"{"operation":"classify-and-answer","sourceTranscriptRevision":0,"workflow":"live-recording"}"#,
            outputLanguage: "en",
            startedAt: meeting.startedAt.addingTimeInterval(1),
            finishedAt: meeting.startedAt.addingTimeInterval(1.5),
            outcome: .succeeded,
            metricsJSON: #"{"answerUTF8Bytes":32,"questionUTF8Bytes":13}"#)
        let failedRun = GenerationRun(
            meetingID: meeting.id,
            kind: .companion,
            providerID: "foundation-models",
            modelID: "system-language-model",
            inputFingerprint: String(repeating: "d", count: 64),
            configJSON: #"{"operation":"classify-and-answer","sourceTranscriptRevision":0,"workflow":"live-recording"}"#,
            outputLanguage: "en",
            startedAt: meeting.startedAt.addingTimeInterval(1.6),
            finishedAt: meeting.startedAt.addingTimeInterval(1.7),
            outcome: .failed)
        meeting.endedAt = meeting.startedAt.addingTimeInterval(2)
        meeting.language = "en"
        meeting.lifecycleState = .captured

        try await store.installCapturedSnapshot(CapturedMeetingSnapshot(
            meeting: meeting,
            assets: finalized,
            speakers: [speaker],
            segments: [segment],
            contextItems: [note],
            companionCards: [],
            companionArtifacts: [CompanionGenerationArtifact(
                card: card,
                generationRun: successfulRun)],
            companionTerminalRuns: [failedRun]))

        let loadedDetail = try await store.detail(meeting.id)
        let storedDetail = try XCTUnwrap(loadedDetail)
        let storedAssets = try await store.audioAssets(for: meeting.id)
        let storedNotes = try await store.contextItems(for: meeting.id)
        let storedCards = try await store.companionCards(for: meeting.id)
        let storedRuns = try await store.generationRuns(for: meeting.id)
        XCTAssertEqual(storedDetail.meeting.lifecycleState, .captured)
        XCTAssertEqual(storedDetail.meeting.language, "en")
        XCTAssertEqual(storedDetail.speakers.map(\.id), [speaker.id])
        XCTAssertEqual(storedDetail.segments.map(\.id), [segment.id])
        XCTAssertEqual(storedAssets.map(\.healthStatus), [.healthy, .missing])
        XCTAssertEqual(storedAssets.first?.relativePath, AudioCapturePath.publishedRelativePath(
            directory: meeting.audioDirectory!, channel: .microphone))
        XCTAssertEqual(storedAssets.first?.sha256, String(repeating: "a", count: 64))
        XCTAssertEqual(storedNotes.map(\.id), [note.id])
        XCTAssertEqual(storedCards.map(\.id), [card.id])
        XCTAssertEqual(Set(storedRuns.map(\.id)), Set([successfulRun.id, failedRun.id]))
        let linkedRunID = try await store.database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT generationRunID FROM companionCard WHERE id = ?",
                arguments: [card.id.uuidString])
        }
        XCTAssertEqual(linkedRunID, successfulRun.id.rawValue.uuidString)
    }

    func testCapturedSnapshotAtomicallyAdmitsInitialProcessing() async throws {
        let store = try MeetingStore.inMemory()
        var meeting = shell()
        let reservation = assets(for: meeting, channels: [.microphone])[0]
        try await store.beginRecording(meeting, assets: [reservation])
        let speaker = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .microphone,
            text: "The durable worker owns the next step.",
            startTime: 0,
            endTime: 2,
            isFinal: true)
        meeting.endedAt = meeting.startedAt.addingTimeInterval(2)
        meeting.language = "en"
        meeting.lifecycleState = .captured
        let timestamp = meeting.startedAt.addingTimeInterval(3)

        let jobs = try await store.installCapturedSnapshot(
            CapturedMeetingSnapshot(
                meeting: meeting,
                assets: [published(reservation)],
                speakers: [speaker],
                segments: [segment],
                contextItems: [],
                companionCards: []),
            enqueue: [ProcessingJobRequest(
                kind: .diarization,
                inputFingerprint: "initial-diarization",
                priority: 20,
                maxAttempts: 3)],
            at: timestamp)

        let loadedDetail = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(loadedDetail)
        let storedJobs = try await store.processingJobs(for: meeting.id)
        let storedAssets = try await store.audioAssets(for: meeting.id)
        XCTAssertEqual(jobs.map(\.id), storedJobs.map(\.id))
        XCTAssertEqual(storedJobs.map(\.state), [.pending])
        XCTAssertEqual(storedJobs.map(\.kind), [.diarization])
        XCTAssertEqual(detail.meeting.lifecycleState, .processing)
        XCTAssertEqual(detail.segments.map(\.id), [segment.id])
        XCTAssertEqual(storedAssets.map(\.healthStatus), [.healthy])
    }

    func testInitialJobFailureRollsCapturedSnapshotBack() async throws {
        let store = try MeetingStore.inMemory()
        var meeting = shell()
        let reservation = assets(for: meeting, channels: [.microphone])[0]
        try await store.beginRecording(meeting, assets: [reservation])
        let speaker = Speaker(meetingID: meeting.id, label: "Me", isMe: true)
        let segment = TranscriptSegment(
            meetingID: meeting.id,
            speakerID: speaker.id,
            channel: .microphone,
            text: "Neither half may commit alone.",
            startTime: 0,
            endTime: 2,
            isFinal: true)
        meeting.endedAt = meeting.startedAt.addingTimeInterval(2)
        meeting.lifecycleState = .captured
        try await store.database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_initial_processing_job
                BEFORE INSERT ON processingJob
                BEGIN
                    SELECT RAISE(ABORT, 'injected initial job failure');
                END
                """)
        }

        do {
            try await store.installCapturedSnapshot(
                CapturedMeetingSnapshot(
                    meeting: meeting,
                    assets: [published(reservation)],
                    speakers: [speaker],
                    segments: [segment],
                    contextItems: [],
                    companionCards: []),
                enqueue: [ProcessingJobRequest(
                    kind: .diarization,
                    inputFingerprint: "initial-diarization")])
            XCTFail("job admission failure must roll back the captured snapshot")
        } catch {
            XCTAssertTrue(error is DatabaseError, "wrong error: \(error)")
        }

        let loadedDetail = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(loadedDetail)
        let storedJobs = try await store.processingJobs(for: meeting.id)
        XCTAssertEqual(detail.meeting.lifecycleState, .recording)
        XCTAssertTrue(detail.speakers.isEmpty)
        XCTAssertTrue(detail.segments.isEmpty)
        XCTAssertTrue(storedJobs.isEmpty)
        let storedAssets = try await store.audioAssets(for: meeting.id)
        XCTAssertEqual(storedAssets.map(\.healthStatus), [.pending])
        XCTAssertEqual(storedAssets.map(\.relativePath), [reservation.relativePath])
    }

    func testCapturedSnapshotRollsBackEveryWriteWhenAssetPublicationConflicts() async throws {
        let store = try MeetingStore.inMemory()
        let directory = "Audio/shared-finalization"
        let owner = shell(directory: directory)
        let ownerReservation = assets(for: owner, channels: [.microphone])[0]
        try await store.beginRecording(owner, assets: [ownerReservation])
        try await store.database.write { db in
            try db.execute(
                sql: "UPDATE audioAsset SET relativePath = ? WHERE id = ?",
                arguments: [
                    AudioCapturePath.publishedRelativePath(
                        directory: directory, channel: .microphone),
                    ownerReservation.id.rawValue.uuidString,
                ])
        }

        var candidate = shell(directory: directory)
        let candidateReservation = assets(for: candidate, channels: [.microphone])[0]
        try await store.beginRecording(candidate, assets: [candidateReservation])
        let speaker = Speaker(meetingID: candidate.id, label: "Me", isMe: true)
        let segment = TranscriptSegment(
            meetingID: candidate.id,
            speakerID: speaker.id,
            channel: .microphone,
            text: "This transaction must roll back.",
            startTime: 0,
            endTime: 1,
            isFinal: true)
        candidate.endedAt = candidate.startedAt.addingTimeInterval(1)
        candidate.lifecycleState = .captured

        do {
            try await store.installCapturedSnapshot(CapturedMeetingSnapshot(
                meeting: candidate,
                assets: [published(candidateReservation)],
                speakers: [speaker],
                segments: [segment],
                contextItems: [],
                companionCards: []))
            XCTFail("the final path collision must reject the whole snapshot")
        } catch {
            XCTAssertTrue(error is DatabaseError, "wrong error: \(error)")
        }

        let loadedDetail = try await store.detail(candidate.id)
        let detail = try XCTUnwrap(loadedDetail)
        let candidateAssets = try await store.audioAssets(for: candidate.id)
        XCTAssertEqual(detail.meeting.lifecycleState, .recording)
        XCTAssertTrue(detail.speakers.isEmpty)
        XCTAssertTrue(detail.segments.isEmpty)
        XCTAssertEqual(candidateAssets.map(\.healthStatus), [.pending])
        XCTAssertEqual(candidateAssets.map(\.relativePath), [candidateReservation.relativePath])
    }

    func testCapturedSnapshotRejectsInvalidMetadataAndTouchedShell() async throws {
        let metadataStore = try MeetingStore.inMemory()
        var metadataMeeting = shell()
        let metadataReservation = assets(
            for: metadataMeeting, channels: [.microphone])[0]
        try await metadataStore.beginRecording(
            metadataMeeting, assets: [metadataReservation])
        var invalidAsset = published(metadataReservation)
        invalidAsset.sha256 = String(repeating: "A", count: 64)
        metadataMeeting.endedAt = metadataMeeting.startedAt.addingTimeInterval(2)
        metadataMeeting.lifecycleState = .captured

        do {
            try await metadataStore.installCapturedSnapshot(CapturedMeetingSnapshot(
                meeting: metadataMeeting,
                assets: [invalidAsset],
                speakers: [],
                segments: [],
                contextItems: [],
                companionCards: []))
            XCTFail("uppercase checksums must not become finalized evidence")
        } catch {
            XCTAssertTrue(error is StorageError, "wrong error: \(error)")
        }
        let loadedMetadataDetail = try await metadataStore.detail(metadataMeeting.id)
        let metadataDetail = try XCTUnwrap(loadedMetadataDetail)
        XCTAssertEqual(metadataDetail.meeting.lifecycleState, .recording)
        let metadataAssets = try await metadataStore.audioAssets(for: metadataMeeting.id)
        XCTAssertEqual(metadataAssets.map(\.id), [metadataReservation.id])
        XCTAssertEqual(metadataAssets.map(\.healthStatus), [.pending])
        XCTAssertEqual(metadataAssets.map(\.relativePath), [metadataReservation.relativePath])

        let shellStore = try MeetingStore.inMemory()
        var touchedMeeting = shell()
        let touchedReservation = assets(for: touchedMeeting, channels: [.microphone])[0]
        try await shellStore.beginRecording(touchedMeeting, assets: [touchedReservation])
        let touchedMeetingKey = touchedMeeting.id.rawValue.uuidString
        try await shellStore.database.write { db in
            try db.execute(
                sql: "UPDATE meeting SET language = 'en' WHERE id = ?",
                arguments: [touchedMeetingKey])
        }
        touchedMeeting.endedAt = touchedMeeting.startedAt.addingTimeInterval(2)
        touchedMeeting.lifecycleState = .captured
        do {
            try await shellStore.installCapturedSnapshot(CapturedMeetingSnapshot(
                meeting: touchedMeeting,
                assets: [published(touchedReservation)],
                speakers: [],
                segments: [],
                contextItems: [],
                companionCards: []))
            XCTFail("a shell changed after reservation must not be replaced")
        } catch {
            XCTAssertTrue(error is StorageError, "wrong error: \(error)")
        }
        let loadedTouchedDetail = try await shellStore.detail(touchedMeeting.id)
        let touchedDetail = try XCTUnwrap(loadedTouchedDetail)
        XCTAssertEqual(touchedDetail.meeting.lifecycleState, .recording)
        XCTAssertEqual(touchedDetail.meeting.language, "en")
        let touchedAssets = try await shellStore.audioAssets(for: touchedMeeting.id)
        XCTAssertEqual(touchedAssets.map(\.id), [touchedReservation.id])
        XCTAssertEqual(touchedAssets.map(\.healthStatus), [.pending])
        XCTAssertEqual(touchedAssets.map(\.relativePath), [touchedReservation.relativePath])
    }

    func testRecoveredCaptureAssetsCommitAtomicallyAndRepeatSafely() async throws {
        let store = try MeetingStore.inMemory()
        var meeting = shell()
        let reservations = assets(for: meeting, channels: [.microphone, .system])
        let capturedAssets = [published(reservations[0]), reservations[1]]
        meeting.endedAt = meeting.startedAt.addingTimeInterval(2)
        let capturedAt = try XCTUnwrap(meeting.endedAt)
        meeting.lifecycleState = .captured
        try await store.beginRecording(shell(id: meeting.id), assets: reservations)
        try await store.installCapturedSnapshot(CapturedMeetingSnapshot(
            meeting: meeting,
            assets: capturedAssets,
            speakers: [],
            segments: [],
            contextItems: [],
            companionCards: []))
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id,
                channel: .microphone,
                text: "Recovered publication must preserve this transcript.",
                startTime: 0,
                endTime: 2,
                isFinal: true)
        ])
        meeting.lifecycleState = .needsAttention
        meeting.lastProcessingError = "capture.publication.failed"
        try await store.save(meeting)
        _ = try await store.enqueueProcessingJobs(
            for: meeting.id,
            requests: [ProcessingJobRequest(
                kind: .index, inputFingerprint: "captured-index")],
            at: capturedAt)
        let claimedValue = try await store.claimNextProcessingJob(
            kinds: [.index], owner: "worker", leaseDuration: 30, at: capturedAt)
        let claimed = try XCTUnwrap(claimedValue)
        _ = try await store.completeProcessingJob(
            claimed.id, owner: "worker", at: capturedAt.addingTimeInterval(0.5))
        let publicationFailure = try await store.detail(meeting.id)
        XCTAssertEqual(publicationFailure?.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(
            publicationFailure?.meeting.lastProcessingError,
            "capture.publication.failed")

        var recoveredSystem = reservations[1]
        recoveredSystem.healthStatus = .missing
        recoveredSystem.updatedAt = capturedAt.addingTimeInterval(1)
        var conflictingMicrophone = capturedAssets[0]
        conflictingMicrophone.sha256 = String(repeating: "b", count: 64)
        do {
            try await store.installRecoveredCaptureAssets(
                [recoveredSystem, conflictingMicrophone],
                for: meeting.id,
                at: capturedAt.addingTimeInterval(1))
            XCTFail("a conflicting finalized asset must roll back every recovered row")
        } catch {
            guard case StorageError.invalidRecordingReservation = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        var stored = try await store.audioAssets(for: meeting.id)
        XCTAssertEqual(stored.map(\.healthStatus), [.healthy, .pending])
        let failedDetail = try await store.detail(meeting.id)
        XCTAssertEqual(failedDetail?.meeting.lifecycleState, .needsAttention)

        try await store.installRecoveredCaptureAssets(
            [recoveredSystem, capturedAssets[0]],
            for: meeting.id,
            at: capturedAt.addingTimeInterval(2))
        try await store.installRecoveredCaptureAssets(
            [recoveredSystem, capturedAssets[0]],
            for: meeting.id,
            at: capturedAt.addingTimeInterval(3))
        stored = try await store.audioAssets(for: meeting.id)
        XCTAssertEqual(stored.map(\.healthStatus), [.healthy, .missing])
        XCTAssertNil(stored[1].sha256)
        let recoveredDetail = try await store.detail(meeting.id)
        XCTAssertEqual(recoveredDetail?.meeting.lifecycleState, .ready)
        XCTAssertNil(recoveredDetail?.meeting.lastProcessingError)
    }

    func testInterruptedShellInstallsRecoveredSnapshotDirectlyIntoAttention() async throws {
        let store = try MeetingStore.inMemory()
        let meeting = shell()
        let reservation = assets(for: meeting, channels: [.microphone])[0]
        try await store.beginRecording(meeting, assets: [reservation])
        let interruptedEnd = meeting.startedAt.addingTimeInterval(2)
        let interrupted = try await store.markMeetingNeedsAttention(
            meeting.id,
            errorCode: "capture.publication.failed",
            endedAt: interruptedEnd,
            at: interruptedEnd)

        var recovered = interrupted
        recovered.lifecycleState = .needsAttention
        recovered.lastProcessingError = "transcription.empty"
        try await store.installCapturedSnapshot(CapturedMeetingSnapshot(
            meeting: recovered,
            assets: [published(reservation)],
            speakers: [],
            segments: [],
            contextItems: [],
            companionCards: []))

        let loaded = try await store.detail(meeting.id)
        let detail = try XCTUnwrap(loaded)
        XCTAssertEqual(detail.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(detail.meeting.endedAt, interruptedEnd)
        XCTAssertEqual(detail.meeting.lastProcessingError, "transcription.empty")
        let storedAssets = try await store.audioAssets(for: meeting.id)
        XCTAssertEqual(storedAssets.map(\.healthStatus), [.healthy])

        do {
            _ = try await store.markMeetingNeedsAttention(
                meeting.id, errorCode: "arbitrary caller text")
            XCTFail("recovery errors must use stable machine-readable codes")
        } catch {
            guard case StorageError.invalidRecordingReservation = error else {
                return XCTFail("wrong error: \(error)")
            }
        }

        var ready = detail.meeting
        ready.lifecycleState = .ready
        ready.lastProcessingError = nil
        try await store.save(ready)
        do {
            _ = try await store.markMeetingNeedsAttention(
                meeting.id, errorCode: "processing.interrupted")
            XCTFail("launch recovery must not downgrade a ready meeting")
        } catch {
            guard case StorageError.invalidRecordingReservation = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }
}
