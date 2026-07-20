import ApplicationKit
import Foundation
import PortavozCore
import StorageKit
import XCTest

final class RecoverInterruptedMeetingsUseCaseTests: XCTestCase {
    func testExpiredLeasesRecoverBeforeCandidatesAndRequireOneInvalidation() async {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(state: .captured)
        let asset = fixture.publishedAsset(for: meeting)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [asset]],
            states: [meeting.id: fixture.state(meeting)],
            meetingsWithJobs: [meeting.id],
            expiredLeaseCount: 2)

        let result = await fixture.useCase(store: store).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.recoveredLeaseCount, 2)
        XCTAssertEqual(result.reconciledMeetingCount, 0)
        XCTAssertTrue(result.libraryInvalidationRequired)
        let state = await store.probeState()
        XCTAssertEqual(Array(state.events.prefix(3)), ["leases", "candidates", "assets"])
        XCTAssertTrue(state.timestamps.allSatisfy { $0 == fixture.now })
    }

    func testActiveRecordingDefersEveryCandidateWithoutReadingItsAssets() async {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(state: .recording)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [fixture.pendingAsset(for: meeting)]],
            states: [meeting.id: fixture.state(meeting)])
        let activity = RecoveryActivityProbe(responses: [true])

        let result = await fixture.useCase(store: store, activity: activity).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.deferredMeetingCount, 1)
        XCTAssertFalse(result.libraryInvalidationRequired)
        let state = await store.probeState()
        XCTAssertEqual(state.events, ["leases", "candidates"])
    }

    func testRecordingShellWithPublishedEvidenceInstallsAttentionSnapshot() async throws {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(state: .recording)
        let pending = fixture.pendingAsset(for: meeting)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [pending]],
            states: [meeting.id: fixture.state(meeting)])
        let files = RecoveryFilesProbe(publishedDurations: [pending.id: 4])

        let result = await fixture.useCase(store: store, files: files).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.reconciledMeetingCount, 1)
        let state = await store.probeState()
        let snapshot = try XCTUnwrap(state.installedSnapshots.first)
        XCTAssertEqual(snapshot.meeting.lifecycleState, .needsAttention)
        XCTAssertEqual(snapshot.meeting.lastProcessingError, "transcription.empty")
        XCTAssertEqual(
            snapshot.meeting.endedAt,
            meeting.startedAt.addingTimeInterval(4))
        XCTAssertEqual(snapshot.assets.map(\.healthStatus), [.healthy])
        XCTAssertEqual(snapshot.assets.map(\.relativePath), [
            AudioCapturePath.publishedRelativePath(
                directory: fixture.directory,
                channel: .microphone),
        ])
        XCTAssertTrue(snapshot.segments.isEmpty)
    }

    func testRecordingShellWithoutEvidenceUsesGuardedDiscard() async {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(state: .recording)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [fixture.pendingAsset(for: meeting)]],
            states: [meeting.id: fixture.state(meeting)],
            discardResults: [meeting.id: true])

        let result = await fixture.useCase(store: store).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.reconciledMeetingCount, 1)
        let state = await store.probeState()
        XCTAssertEqual(state.discardedMeetings, [meeting.id])
        XCTAssertTrue(state.markedCodes.isEmpty)
        XCTAssertTrue(state.installedAssetBatches.isEmpty)
    }

    func testRetainedCaptureShellPersistsMissingEvidenceAndGuidance() async {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(
            state: .needsAttention,
            errorCode: "capture.start.failed")
        let pending = fixture.pendingAsset(for: meeting)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [pending]],
            states: [meeting.id: fixture.state(meeting)])

        let result = await fixture.useCase(store: store).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.reconciledMeetingCount, 1)
        let state = await store.probeState()
        XCTAssertEqual(state.installedAssetBatches.first?.map(\.healthStatus), [.missing])
        XCTAssertEqual(state.markedCodes[meeting.id], ["capture.recovery.missing"])
    }

    func testRecoveredPendingAssetOnCapturedMeetingMarksEmptyTranscript() async {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(state: .captured)
        let pending = fixture.pendingAsset(for: meeting)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [pending]],
            states: [meeting.id: fixture.state(meeting)])
        let files = RecoveryFilesProbe(publishedDurations: [pending.id: 2])

        let result = await fixture.useCase(store: store, files: files).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.reconciledMeetingCount, 1)
        let state = await store.probeState()
        XCTAssertEqual(state.installedAssetBatches.count, 1)
        XCTAssertEqual(state.markedCodes[meeting.id], ["transcription.empty"])
        let installIndex = try? XCTUnwrap(state.events.firstIndex(of: "install-assets"))
        let markIndex = try? XCTUnwrap(state.events.firstIndex(of: "mark"))
        XCTAssertLessThan(installIndex ?? .max, markIndex ?? .min)
    }

    func testInterruptedProcessingWithTranscriptMarksProcessingInterrupted() async {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(state: .processing)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [fixture.publishedAsset(for: meeting)]],
            states: [meeting.id: fixture.state(
                meeting,
                segments: [fixture.segment(for: meeting)])])

        let result = await fixture.useCase(store: store).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.reconciledMeetingCount, 1)
        let state = await store.probeState()
        XCTAssertEqual(state.markedCodes[meeting.id], ["processing.interrupted"])
    }

    func testExistingProcessingJobPreventsLifecycleRewrite() async {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(state: .processing)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [fixture.publishedAsset(for: meeting)]],
            states: [meeting.id: fixture.state(meeting)],
            meetingsWithJobs: [meeting.id])

        let result = await fixture.useCase(store: store).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.reconciledMeetingCount, 0)
        XCTAssertFalse(result.libraryInvalidationRequired)
        let state = await store.probeState()
        XCTAssertTrue(state.markedCodes.isEmpty)
    }

    func testPublicationFailureWithContentReconcilesPendingEvidenceWithoutReplacement() async throws {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(
            state: .needsAttention,
            errorCode: "capture.publication.failed")
        let pending = fixture.pendingAsset(for: meeting)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: [pending]],
            states: [meeting.id: fixture.state(
                meeting,
                segments: [fixture.segment(for: meeting)])],
            snapshotFailureMeetings: [meeting.id])
        let files = RecoveryFilesProbe(publishedDurations: [pending.id: 2])

        let result = await fixture.useCase(store: store, files: files).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.reconciledMeetingCount, 1)
        let state = await store.probeState()
        XCTAssertEqual(state.installedAssetBatches.count, 1)
        XCTAssertTrue(state.installedSnapshots.isEmpty)
        let final = try XCTUnwrap(state.states[meeting.id]?.meeting)
        XCTAssertEqual(final.lifecycleState, .ready)
        XCTAssertNil(final.lastProcessingError)
    }

    func testTypedCaptureFailureIsPreservedAndNextMeetingStillRecovers() async {
        let fixture = RecoveryFixture()
        let first = fixture.meeting(
            id: MeetingID(rawValue: UUID(
                uuidString: "10101010-1010-1010-1010-101010101010")!),
            state: .recording)
        let second = fixture.meeting(
            id: MeetingID(rawValue: UUID(
                uuidString: "20202020-2020-2020-2020-202020202020")!),
            state: .recording)
        let firstAsset = fixture.pendingAsset(for: first)
        let secondAsset = fixture.pendingAsset(for: second)
        let store = RecoveryStoreProbe(
            candidates: [first, second],
            assets: [first.id: [firstAsset], second.id: [secondAsset]],
            states: [first.id: fixture.state(first), second.id: fixture.state(second)],
            discardResults: [second.id: true])
        let files = RecoveryFilesProbe(errors: [
            firstAsset.id: .ambiguousCapture(.microphone),
        ])

        let result = await fixture.useCase(store: store, files: files).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.preservedFailureCount, 1)
        XCTAssertEqual(result.reconciledMeetingCount, 1)
        XCTAssertTrue(result.libraryInvalidationRequired)
        let state = await store.probeState()
        XCTAssertEqual(state.markedCodes[first.id], ["capture.recovery.ambiguous"])
        XCTAssertEqual(state.discardedMeetings, [second.id])
    }

    func testCandidateLoadFailureKeepsReleasedNoInvalidationTiming() async {
        let fixture = RecoveryFixture()
        let store = RecoveryStoreProbe(
            candidateError: .candidateLoad,
            expiredLeaseCount: 1)

        let result = await fixture.useCase(store: store).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.recoveredLeaseCount, 1)
        XCTAssertFalse(result.libraryInvalidationRequired)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues.first?.stage, .candidateLoading)
    }

    func testFailurePreservationErrorIsReportedWithoutHidingInvalidation() async {
        let fixture = RecoveryFixture()
        let meeting = fixture.meeting(state: .recording)
        let store = RecoveryStoreProbe(
            candidates: [meeting],
            assets: [meeting.id: []],
            states: [meeting.id: fixture.state(meeting)],
            markFailureMeetings: [meeting.id])

        let result = await fixture.useCase(store: store).execute(
            RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.preservedFailureCount, 1)
        XCTAssertTrue(result.libraryInvalidationRequired)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertEqual(result.issues.first?.stage, .failurePreservation(meeting.id))
    }

    func testRealStoreAdapterProtectsReadyAndDiscardsOnlyEmptyRecordingShell() async throws {
        let fixture = RecoveryFixture()
        let store = try MeetingStore.inMemory()
        let ready = fixture.meeting(
            id: MeetingID(rawValue: UUID(
                uuidString: "30303030-3030-3030-3030-303030303030")!),
            state: .ready)
        try await store.save(ready)
        let recording = fixture.meeting(
            id: MeetingID(rawValue: UUID(
                uuidString: "40404040-4040-4040-4040-404040404040")!),
            state: .recording)
        try await store.beginRecording(
            recording,
            assets: [fixture.pendingAsset(for: recording)])

        let result = await RecoverInterruptedMeetings(
            store: store,
            files: RecoveryFilesProbe(),
            activity: RecoveryActivityProbe(),
            now: { fixture.now })
            .execute(RecoverInterruptedMeetingsRequest())

        XCTAssertEqual(result.reconciledMeetingCount, 1)
        let readyDetail = try await store.detail(ready.id)
        let recordingDetail = try await store.detail(recording.id)
        XCTAssertNotNil(readyDetail)
        XCTAssertNil(recordingDetail)
    }
}

private struct RecoveryFixture {
    let defaultMeetingID = MeetingID(rawValue: UUID(
        uuidString: "90909090-9090-9090-9090-909090909090")!)
    let now = Date(timeIntervalSince1970: 1_783_695_900)
    let startedAt = Date(timeIntervalSince1970: 1_783_695_600)
    let directory = "Audio/recovery-use-case"

    func meeting(
        id: MeetingID? = nil,
        state: MeetingLifecycleState,
        errorCode: String? = nil
    ) -> Meeting {
        let meetingID = id ?? defaultMeetingID
        return Meeting(
            id: meetingID,
            title: "Interrupted recording",
            startedAt: startedAt,
            endedAt: state == .recording ? nil : startedAt.addingTimeInterval(2),
            audioDirectory: directory,
            retention: .keep,
            lifecycleState: state,
            lastProcessingError: errorCode)
    }

    func pendingAsset(for meeting: Meeting) -> AudioAsset {
        AudioAsset.pendingCapture(
            meetingID: meeting.id,
            channel: .microphone,
            relativePath: AudioCapturePath.stagingRelativePath(
                directory: directory,
                channel: .microphone),
            at: meeting.startedAt)
    }

    func publishedAsset(for meeting: Meeting) -> AudioAsset {
        published(pendingAsset(for: meeting), duration: 2, timestamp: now)
    }

    func state(
        _ meeting: Meeting,
        segments: [TranscriptSegment] = []
    ) -> RecoverInterruptedMeetingState {
        RecoverInterruptedMeetingState(meeting: meeting, segments: segments)
    }

    func segment(for meeting: Meeting) -> TranscriptSegment {
        TranscriptSegment(
            meetingID: meeting.id,
            channel: .microphone,
            text: "La evidencia durable continúa.",
            language: "es",
            startTime: 0,
            endTime: 1,
            isFinal: true)
    }

    func useCase(
        store: RecoveryStoreProbe,
        files: RecoveryFilesProbe = RecoveryFilesProbe(),
        activity: RecoveryActivityProbe = RecoveryActivityProbe()
    ) -> RecoverInterruptedMeetings {
        RecoverInterruptedMeetings(
            store: store,
            files: files,
            activity: activity,
            now: { now })
    }
}

private func published(
    _ reservation: AudioAsset,
    duration: TimeInterval,
    timestamp: Date
) -> AudioAsset {
    var asset = reservation
    let directory = reservation.relativePath
        .split(separator: "/")
        .dropLast()
        .joined(separator: "/")
    asset.relativePath = AudioCapturePath.publishedRelativePath(
        directory: directory,
        channel: reservation.channel)
    asset.container = "caf"
    asset.codec = "pcm-s16le"
    asset.sampleRate = 16_000
    asset.channelCount = 1
    asset.durationSeconds = duration
    asset.byteCount = Int64(duration * 32_000)
    asset.sha256 = String(repeating: "a", count: 64)
    asset.healthStatus = .healthy
    asset.peakDBFS = -12
    asset.rmsDBFS = -24
    asset.updatedAt = timestamp
    return asset
}

private enum RecoveryProbeError: Error, LocalizedError {
    case candidateLoad
    case snapshot
    case mark

    var errorDescription: String? { "Recovery probe failed: \(self)" }
}

private actor RecoveryActivityProbe: RecoverInterruptedMeetingsActivity {
    private var responses: [Bool]

    init(responses: [Bool] = []) {
        self.responses = responses
    }

    func recordingPipelineIsActive() async -> Bool {
        responses.isEmpty ? false : responses.removeFirst()
    }
}

private actor RecoveryFilesProbe: RecoverInterruptedMeetingsFiles {
    private let publishedDurations: [AudioAssetID: TimeInterval]
    private let errors: [AudioAssetID: RecoverInterruptedMeetingError]

    init(
        publishedDurations: [AudioAssetID: TimeInterval] = [:],
        errors: [AudioAssetID: RecoverInterruptedMeetingError] = [:]
    ) {
        self.publishedDurations = publishedDurations
        self.errors = errors
    }

    func recoverPendingAsset(
        _ asset: AudioAsset,
        directory: String,
        at timestamp: Date
    ) async throws -> AudioAsset {
        if let error = errors[asset.id] { throw error }
        guard let duration = publishedDurations[asset.id] else {
            var missing = asset
            missing.healthStatus = .missing
            missing.updatedAt = timestamp
            return missing
        }
        return published(asset, duration: duration, timestamp: timestamp)
    }
}

private struct RecoveryStoreProbeState: Sendable {
    let events: [String]
    let timestamps: [Date]
    let discardedMeetings: [MeetingID]
    let installedAssetBatches: [[AudioAsset]]
    let installedSnapshots: [CapturedMeetingSnapshot]
    let markedCodes: [MeetingID: [String]]
    let states: [MeetingID: RecoverInterruptedMeetingState]
}

private actor RecoveryStoreProbe: RecoverInterruptedMeetingsStore {
    private let candidates: [Meeting]
    private let candidateError: RecoveryProbeError?
    private let expiredLeaseCount: Int
    private var assets: [MeetingID: [AudioAsset]]
    private var states: [MeetingID: RecoverInterruptedMeetingState]
    private let meetingsWithJobs: Set<MeetingID>
    private let discardResults: [MeetingID: Bool]
    private let snapshotFailureMeetings: Set<MeetingID>
    private let markFailureMeetings: Set<MeetingID>
    private var events: [String] = []
    private var timestamps: [Date] = []
    private var discardedMeetings: [MeetingID] = []
    private var installedAssetBatches: [[AudioAsset]] = []
    private var installedSnapshots: [CapturedMeetingSnapshot] = []
    private var markedCodes: [MeetingID: [String]] = [:]

    init(
        candidates: [Meeting] = [],
        candidateError: RecoveryProbeError? = nil,
        assets: [MeetingID: [AudioAsset]] = [:],
        states: [MeetingID: RecoverInterruptedMeetingState] = [:],
        meetingsWithJobs: Set<MeetingID> = [],
        discardResults: [MeetingID: Bool] = [:],
        expiredLeaseCount: Int = 0,
        snapshotFailureMeetings: Set<MeetingID> = [],
        markFailureMeetings: Set<MeetingID> = []
    ) {
        self.candidates = candidates
        self.candidateError = candidateError
        self.assets = assets
        self.states = states
        self.meetingsWithJobs = meetingsWithJobs
        self.discardResults = discardResults
        self.expiredLeaseCount = expiredLeaseCount
        self.snapshotFailureMeetings = snapshotFailureMeetings
        self.markFailureMeetings = markFailureMeetings
    }

    func recoverExpiredRecoveryJobs(at timestamp: Date) async throws -> Int {
        events.append("leases")
        timestamps.append(timestamp)
        return expiredLeaseCount
    }

    func recoveryCandidates() async throws -> [Meeting] {
        events.append("candidates")
        if let candidateError { throw candidateError }
        return candidates
    }

    func recoveryAssets(for meetingID: MeetingID) async throws -> [AudioAsset] {
        events.append("assets")
        return assets[meetingID] ?? []
    }

    func recoveryState(
        for meetingID: MeetingID
    ) async throws -> RecoverInterruptedMeetingState? {
        events.append("state")
        return states[meetingID]
    }

    func recoveryHasProcessingJobs(for meetingID: MeetingID) async throws -> Bool {
        events.append("jobs")
        return meetingsWithJobs.contains(meetingID)
    }

    func discardRecoveryShell(_ meetingID: MeetingID) async throws -> Bool {
        events.append("discard")
        guard discardResults[meetingID] ?? false else { return false }
        discardedMeetings.append(meetingID)
        states[meetingID] = nil
        assets[meetingID] = nil
        return true
    }

    func installRecoveryAssets(
        _ recovered: [AudioAsset],
        for meetingID: MeetingID,
        at timestamp: Date
    ) async throws {
        events.append("install-assets")
        timestamps.append(timestamp)
        installedAssetBatches.append(recovered)
        var current = assets[meetingID] ?? []
        let replacements = Dictionary(uniqueKeysWithValues: recovered.map { ($0.id, $0) })
        current = current.map { replacements[$0.id] ?? $0 }
        assets[meetingID] = current
        guard var state = states[meetingID],
            state.meeting.lifecycleState == .needsAttention,
            state.meeting.lastProcessingError == "capture.publication.failed",
            !state.segments.isEmpty,
            !current.contains(where: { $0.healthStatus == .pending }),
            !meetingsWithJobs.contains(meetingID)
        else { return }
        var meeting = state.meeting
        meeting.lifecycleState = .ready
        meeting.lastProcessingError = nil
        state = RecoverInterruptedMeetingState(meeting: meeting, segments: state.segments)
        states[meetingID] = state
    }

    func installRecoverySnapshot(
        _ snapshot: CapturedMeetingSnapshot,
        at timestamp: Date
    ) async throws {
        events.append("install-snapshot")
        timestamps.append(timestamp)
        if snapshotFailureMeetings.contains(snapshot.meeting.id) {
            throw RecoveryProbeError.snapshot
        }
        installedSnapshots.append(snapshot)
        assets[snapshot.meeting.id] = snapshot.assets
        states[snapshot.meeting.id] = RecoverInterruptedMeetingState(
            meeting: snapshot.meeting,
            segments: snapshot.segments)
    }

    func markRecoveryNeedsAttention(
        _ meetingID: MeetingID,
        errorCode: String,
        endedAt: Date,
        at timestamp: Date
    ) async throws -> Meeting {
        events.append("mark")
        timestamps.append(timestamp)
        if markFailureMeetings.contains(meetingID) { throw RecoveryProbeError.mark }
        markedCodes[meetingID, default: []].append(errorCode)
        var meeting = states[meetingID]!.meeting
        meeting.endedAt = meeting.endedAt ?? endedAt
        meeting.lifecycleState = .needsAttention
        meeting.lastProcessingError = errorCode
        states[meetingID] = RecoverInterruptedMeetingState(
            meeting: meeting,
            segments: states[meetingID]?.segments ?? [])
        return meeting
    }

    func probeState() -> RecoveryStoreProbeState {
        RecoveryStoreProbeState(
            events: events,
            timestamps: timestamps,
            discardedMeetings: discardedMeetings,
            installedAssetBatches: installedAssetBatches,
            installedSnapshots: installedSnapshots,
            markedCodes: markedCodes,
            states: states)
    }
}
