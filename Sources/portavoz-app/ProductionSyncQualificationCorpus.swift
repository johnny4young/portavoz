import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

enum ProductionSyncQualificationCorpusState: String, Equatable {
    case absent
    case seed
    case editA
    case editB
    case retry
    case push
    case deleted
}

struct ProductionSyncQualificationCorpusFacts: Equatable {
    let state: ProductionSyncQualificationCorpusState
    let liveMeetings: Int
    let deletedMeetings: Int
}

enum ProductionSyncQualificationCorpus {
    static let sha256 = "4892265a8933b573d65de315d5103bac2b2e2ee5a389597ec6f0261f790991fa"

    static func seed(
        manifest: ProductionSyncQualificationManifest,
        store: MeetingStore
    ) async throws {
        let initial = try await facts(
            expecting: .absent,
            manifest: manifest,
            store: store)
        guard initial.liveMeetings == 0, initial.deletedMeetings == 0 else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
        let values = try fixture(manifest: manifest, state: .seed)
        try await store.save(values.meeting)
        try await store.save(values.speakers)
        try await store.save(values.segments)

        // A meeting created by the current schema is immediately journaled.
        // Acknowledging only this scratch generation models a library that
        // predates sync so Enable cannot silently replace the explicit seed.
        for change in try await store.pendingMeetingSyncChanges() {
            try await store.acknowledgeMeetingSync(change)
        }
        guard try await store.pendingMeetingSyncChanges(limit: 1).isEmpty else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
        _ = try await facts(
            expecting: .seed,
            manifest: manifest,
            store: store)
    }

    static func update(
        to state: ProductionSyncQualificationCorpusState,
        from expected: ProductionSyncQualificationCorpusState,
        manifest: ProductionSyncQualificationManifest,
        store: MeetingStore
    ) async throws {
        guard [.editA, .editB, .retry, .push].contains(state) else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
        _ = try await facts(
            expecting: expected,
            manifest: manifest,
            store: store)
        guard var meeting = try await store.detail(
            MeetingID(rawValue: manifest.corpus.meetingID))?.meeting
        else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
        meeting.title = title(for: state)
        try await store.save(meeting)
        _ = try await facts(
            expecting: state,
            manifest: manifest,
            store: store)
    }

    static func delete(
        manifest: ProductionSyncQualificationManifest,
        store: MeetingStore
    ) async throws {
        _ = try await facts(
            expecting: .push,
            manifest: manifest,
            store: store)
        try await DeleteMeeting(store: store).execute(
            MeetingID(rawValue: manifest.corpus.meetingID))
        _ = try await facts(
            expecting: .deleted,
            manifest: manifest,
            store: store)
    }

    static func facts(
        expecting state: ProductionSyncQualificationCorpusState,
        manifest: ProductionSyncQualificationManifest,
        store: MeetingStore
    ) async throws -> ProductionSyncQualificationCorpusFacts {
        guard manifest.corpus.sha256 == sha256 else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
        let all = try await store.meetings(includeDeleted: true)
        let live = try await store.meetings()
        let deleted = try await store.deletedMeetings()
        let meetingID = MeetingID(rawValue: manifest.corpus.meetingID)
        switch state {
        case .absent:
            guard all.isEmpty, live.isEmpty, deleted.isEmpty else {
                throw ProductionSyncQualificationError.invalidCorpus
            }
        case .deleted:
            guard all.count == 1,
                  all.first?.id == meetingID,
                  live.isEmpty,
                  deleted.count == 1,
                  deleted.first?.id == meetingID
            else {
                throw ProductionSyncQualificationError.invalidCorpus
            }
        case .seed, .editA, .editB, .retry, .push:
            guard all.count == 1,
                  live.count == 1,
                  deleted.isEmpty,
                  let detail = try await store.detail(meetingID)
            else {
                throw ProductionSyncQualificationError.invalidCorpus
            }
            try validate(
                detail,
                state: state,
                manifest: manifest)
        }
        return ProductionSyncQualificationCorpusFacts(
            state: state,
            liveMeetings: live.count,
            deletedMeetings: deleted.count)
    }

    private static func validate(
        _ detail: MeetingDetail,
        state: ProductionSyncQualificationCorpusState,
        manifest: ProductionSyncQualificationManifest
    ) throws {
        let expected = try fixture(manifest: manifest, state: state)
        let actualMeeting = detail.meeting
        let expectedMeeting = expected.meeting
        guard actualMeeting.id == expectedMeeting.id,
              actualMeeting.title == expectedMeeting.title,
              actualMeeting.startedAt == expectedMeeting.startedAt,
              actualMeeting.endedAt == expectedMeeting.endedAt,
              actualMeeting.language == expectedMeeting.language,
              actualMeeting.audioDirectory == nil,
              actualMeeting.retention == .keep,
              actualMeeting.visibility == "private",
              actualMeeting.lifecycleState == .ready,
              actualMeeting.transcriptRevision == 0,
              actualMeeting.lastProcessingError == nil,
              detail.summaries.isEmpty
        else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
        let speakers = detail.speakers.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        let expectedSpeakers = expected.speakers.sorted {
            $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
        }
        guard speakers.count == expectedSpeakers.count,
              zip(speakers, expectedSpeakers).allSatisfy({ left, right in
                left.id == right.id
                    && left.meetingID == right.meetingID
                    && left.label == right.label
                    && left.displayName == right.displayName
                    && left.isMe == right.isMe
                    && left.personID == nil
              })
        else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
        let segments = detail.segments.sorted { $0.id.uuidString < $1.id.uuidString }
        let expectedSegments = expected.segments.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        guard segments.count == expectedSegments.count,
              zip(segments, expectedSegments).allSatisfy({ left, right in
                left.id == right.id
                    && left.meetingID == right.meetingID
                    && left.speakerID == right.speakerID
                    && left.channel == right.channel
                    && left.text == right.text
                    && left.language == right.language
                    && left.startTime == right.startTime
                    && left.endTime == right.endTime
                    && left.confidence == right.confidence
                    && left.isFinal == right.isFinal
              })
        else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
    }

    private static func fixture(
        manifest: ProductionSyncQualificationManifest,
        state: ProductionSyncQualificationCorpusState
    ) throws -> (
        meeting: Meeting,
        speakers: [Speaker],
        segments: [TranscriptSegment]
    ) {
        guard manifest.corpus.speakerIDs.count == 2,
              manifest.corpus.segmentIDs.count == 2,
              state != .absent,
              state != .deleted
        else {
            throw ProductionSyncQualificationError.invalidCorpus
        }
        let meetingID = MeetingID(rawValue: manifest.corpus.meetingID)
        let firstSpeakerID = SpeakerID(rawValue: manifest.corpus.speakerIDs[0])
        let secondSpeakerID = SpeakerID(rawValue: manifest.corpus.speakerIDs[1])
        let start = Date(timeIntervalSince1970: 1_768_478_400)
        let meeting = Meeting(
            id: meetingID,
            title: title(for: state),
            startedAt: start,
            endedAt: start.addingTimeInterval(600),
            language: nil,
            audioDirectory: nil,
            retention: .keep,
            visibility: "private",
            lifecycleState: .ready)
        let speakers = [
            Speaker(
                id: firstSpeakerID,
                meetingID: meetingID,
                label: "Speaker 1",
                displayName: "Daniel",
                isMe: true),
            Speaker(
                id: secondSpeakerID,
                meetingID: meetingID,
                label: "Speaker 2",
                displayName: "Paulina")
        ]
        let segments = [
            TranscriptSegment(
                id: manifest.corpus.segmentIDs[0],
                meetingID: meetingID,
                speakerID: firstSpeakerID,
                channel: .microphone,
                text: "We approved the public qualification plan.",
                language: "en",
                startTime: 0,
                endTime: 4,
                confidence: 1,
                isFinal: true),
            TranscriptSegment(
                id: manifest.corpus.segmentIDs[1],
                meetingID: meetingID,
                speakerID: secondSpeakerID,
                channel: .system,
                text: "Aprobamos el plan público de calificación.",
                language: "es",
                startTime: 5,
                endTime: 9,
                confidence: 1,
                isFinal: true)
        ]
        return (meeting, speakers, segments)
    }

    private static func title(
        for state: ProductionSyncQualificationCorpusState
    ) -> String {
        switch state {
        case .seed:
            "Portavoz public sync qualification"
        case .editA:
            "Portavoz public sync qualification · edit A"
        case .editB:
            "Portavoz public sync qualification · edit B"
        case .retry:
            "Portavoz public sync qualification · retry"
        case .push:
            "Portavoz public sync qualification · push"
        case .absent, .deleted:
            ""
        }
    }
}
