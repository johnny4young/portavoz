import Foundation
import PortavozCore
import Synchronization
import Testing

@testable import ApplicationKit
@testable import StorageKit

struct TrimMeetingAudioAdmissionTests {
    @Test(arguments: [false, true], [false, true])
    func rejectsWorkQueuedAfterAdmissionWithoutChangingTheTranscript(
        running: Bool, restoredReadySnapshot: Bool
    ) async throws {
        let (store, meeting) = try await fixture()
        #expect(try await store.canTrimMeetingAudio(
            meetingID: meeting.id, relativeAudioDirectory: "Audio/trim-admission"))
        try await startJob(in: store, meetingID: meeting.id, running: running)
        if restoredReadySnapshot {
            // A stale metadata save cannot make an active job safe to overlap.
            try await store.save(meeting)
            let restored = try #require(try await store.detail(meeting.id))
            #expect(restored.meeting.lifecycleState == .ready)
        }
        #expect(try await store.canTrimMeetingAudio(
            meetingID: meeting.id, relativeAudioDirectory: "Audio/trim-admission") == false)

        do {
            try await store.trimMeetingTail(
                meetingID: meeting.id, expectedTranscriptRevision: 2, cutoff: 390)
            Issue.record("Trim must reject processing that started after admission")
        } catch StorageError.audioTrimUnavailable(let meetingID) {
            #expect(meetingID == meeting.id)
        }

        try await expectUnchangedTranscript(in: store, meeting: meeting)
        let job = try #require(try await store.processingJobs(for: meeting.id).first)
        #expect(job.state == (running ? .running : .pending))
    }

    @Test
    func workStartedDuringStagingDiscardsCopiesWithoutSwappingAudio() async throws {
        let (store, meeting) = try await fixture()
        let trimmer = AdmissionRaceTrimmer(store: store, meetingID: meeting.id)
        let useCase = TrimMeetingAudioTail(
            resolver: AdmissionRaceResolver(), trimmer: trimmer, store: store)
        let detail = try #require(try await store.detail(meeting.id))

        do {
            _ = try await useCase.execute(.init(
                meetingID: meeting.id, relativeAudioDirectory: "Audio/trim-admission",
                transcriptRevision: 2, segments: detail.segments, duration: 9_000))
            Issue.record("Trim must reject processing that starts while staging")
        } catch TrimMeetingAudioTailError.unavailable {
            // The existing localized processing-wait message remains the app outcome.
        }

        #expect(trimmer.events.withLock { $0 } == ["stage", "discard"])
        try await expectUnchangedTranscript(in: store, meeting: meeting)
        let job = try #require(try await store.processingJobs(for: meeting.id).first)
        #expect(job.state == .running)
    }

    private func fixture() async throws -> (MeetingStore, Meeting) {
        let store = try MeetingStore.inMemory()
        let start = Date(timeIntervalSince1970: 1_000)
        let meeting = Meeting(
            title: "Trim admission", startedAt: start, endedAt: start.addingTimeInterval(9_000),
            audioDirectory: "Audio/trim-admission", lifecycleState: .ready, transcriptRevision: 2)
        try await store.save(meeting)
        try await store.save([
            TranscriptSegment(
                meetingID: meeting.id, channel: .system, text: "Kept line", startTime: 0,
                endTime: 380, isFinal: true),
            TranscriptSegment(
                meetingID: meeting.id, channel: .system, text: "Later line", startTime: 500,
                endTime: 520, isFinal: true),
        ])
        return (store, meeting)
    }

    private func expectUnchangedTranscript(in store: MeetingStore, meeting: Meeting) async throws {
        let detail = try #require(try await store.detail(meeting.id))
        #expect(detail.meeting.transcriptRevision == 2)
        #expect(detail.meeting.endedAt == meeting.endedAt)
        #expect(detail.segments.map(\.endTime) == [380, 520])
    }
}

private func startJob(in store: MeetingStore, meetingID: MeetingID, running: Bool) async throws {
    _ = try await store.enqueueProcessingJobs(
        for: meetingID, requests: [.init(kind: .diarization, inputFingerprint: "trim-admission")])
    if running {
        let job = try await store.claimNextProcessingJob(
            kinds: [.diarization], owner: "trim-admission-test", leaseDuration: 60, at: Date())
        #expect(job?.state == .running)
    }
}

private struct AdmissionRaceResolver: MeetingAudioChannelResolving {
    func resolve(relativeAudioDirectory: String) throws -> MeetingAudioChannels {
        MeetingAudioChannels(system: URL(fileURLWithPath: "/tmp/trim-admission-system.caf"), microphone: nil)
    }
}

private final class AdmissionRaceTrimmer: MeetingAudioTrimming {
    let store: MeetingStore
    let meetingID: MeetingID
    let events = Mutex<[String]>([])

    init(store: MeetingStore, meetingID: MeetingID) {
        self.store = store
        self.meetingID = meetingID
    }

    func stageTrim(_ files: [URL], cutoff: TimeInterval) async throws -> [URL] {
        events.withLock { $0.append("stage") }
        try await startJob(in: store, meetingID: meetingID, running: true)
        return files
    }

    func commitTrim(originals: [URL], staged: [URL]) throws {
        events.withLock { $0.append("swap") }
    }

    func discardTrim(_ staged: [URL]) {
        events.withLock { $0.append("discard") }
    }
}
