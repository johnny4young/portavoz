import ApplicationKit
import DiarizationKit
import Foundation
import PortavozCore
import XCTest

@testable import StorageKit

final class StartRecordingUseCaseTests: XCTestCase {
    func testSuccessPreparesReservesThenStartsWithExactLivePolicy() async throws {
        let fixture = StartRecordingFixture()
        let dependencies = StartRecordingDependencies(
            preferences: fixture.preferences,
            startedMeetingCount: 2)
        let live = StartRecordingLiveProbe()

        let result = await fixture.useCase(dependencies).execute(StartRecordingRequest(
            callbacks: StartRecordingLiveCallbacks(
                caption: { await live.record(caption: $0) },
                chunk: { chunk in Task { await live.record(chunk: chunk) } })))

        guard case .started(let commit) = result else {
            return XCTFail("recording should start")
        }
        let state = await dependencies.state()
        XCTAssertEqual(commit.reservation.meeting.id, fixture.meetingID)
        XCTAssertEqual(commit.reservation.meeting.title, "03 Recording")
        XCTAssertEqual(commit.reservation.meeting.lifecycleState, .recording)
        XCTAssertEqual(commit.reservation.meeting.audioDirectory, fixture.directory)
        XCTAssertEqual(commit.reservation.assets.map(\.channel), [.microphone, .system])
        XCTAssertEqual(commit.reservation.assets.map(\.healthStatus), [.pending, .pending])
        XCTAssertEqual(commit.tappedMeetingApps, ["Meet"])
        XCTAssertTrue(commit.liveTranscriptionAvailable)
        XCTAssertEqual(state.captureRequest?.meetingID, fixture.meetingID)
        XCTAssertEqual(state.captureRequest?.audioDirectory, fixture.directory)
        XCTAssertNil(state.captureRequest?.languageHint)
        XCTAssertEqual(state.captureRequest?.vocabulary, ["Portavoz", "Trinity"])
        XCTAssertEqual(
            state.events,
            ["preferences", "prepare", "count", "reserve", "start"])
        XCTAssertEqual(state.cancelCount, 0)
        XCTAssertEqual(state.releaseCount, 0)
        try await Task.sleep(for: .milliseconds(10))
        let liveState = await live.state()
        XCTAssertEqual(liveState.captionCount, 1)
        XCTAssertEqual(liveState.chunkCount, 1)
    }

    func testCalendarEventTitleOverridesTemplateAndFixedLanguageIsForwarded() async {
        let fixture = StartRecordingFixture()
        var preferences = fixture.preferences
        preferences = StartRecordingPreferencesSnapshot(
            titleTemplate: preferences.titleTemplate,
            titleLocaleIdentifier: preferences.titleLocaleIdentifier,
            transcriptLanguage: .fixed(.spanish),
            vocabulary: preferences.vocabulary,
            voiceProcessingEnabled: preferences.voiceProcessingEnabled,
            preferredInputDeviceID: preferences.preferredInputDeviceID,
            captureMode: preferences.captureMode)
        let dependencies = StartRecordingDependencies(preferences: preferences)

        let result = await fixture.useCase(dependencies).execute(
            StartRecordingRequest(eventTitle: "Platform Review"))

        guard case .started(let commit) = result else {
            return XCTFail("event-linked recording should start")
        }
        let state = await dependencies.state()
        XCTAssertTrue(commit.reservation.meeting.title.hasSuffix(" Platform Review"))
        XCTAssertEqual(state.captureRequest?.languageHint, "es")
    }

    func testPreparationFailureCleansRuntimeAndSchedulesRelease() async {
        let fixture = StartRecordingFixture()
        let dependencies = StartRecordingDependencies(
            preferences: fixture.preferences,
            prepareError: .prepare)

        let result = await fixture.useCase(dependencies).execute(StartRecordingRequest())

        guard case .preparationFailed(let message) = result else {
            return XCTFail("runtime preparation failure should stay distinct")
        }
        let state = await dependencies.state()
        XCTAssertEqual(message, StartRecordingDependencyError.prepare.localizedDescription)
        XCTAssertEqual(state.events, ["preferences", "prepare", "cancel", "release"])
        XCTAssertNil(state.reservedMeeting)
    }

    func testUnavailableLiveTranscriberStillStartsAudioFirst() async {
        let fixture = StartRecordingFixture()
        let dependencies = StartRecordingDependencies(
            preferences: fixture.preferences,
            liveTranscriptionAvailable: false)

        let result = await fixture.useCase(dependencies).execute(StartRecordingRequest())

        guard case .started(let commit) = result else {
            return XCTFail("missing live transcriber must not block audio")
        }
        let state = await dependencies.state()
        XCTAssertFalse(commit.liveTranscriptionAvailable)
        XCTAssertEqual(
            state.events,
            ["preferences", "prepare", "count", "reserve", "start"])
        XCTAssertEqual(state.cancelCount, 0)
        XCTAssertEqual(state.releaseCount, 0)
        XCTAssertNotNil(state.reservedMeeting)
    }

    func testReservationFailureNeverStartsSourcesAndReleasesPreparedRuntime() async {
        let fixture = StartRecordingFixture()
        let dependencies = StartRecordingDependencies(
            preferences: fixture.preferences,
            reserveError: .reserve)

        let result = await fixture.useCase(dependencies).execute(StartRecordingRequest())

        guard case .captureFailed(let message, let reservation, let invalidations) = result else {
            return XCTFail("reservation failure should be a capture-start failure")
        }
        let state = await dependencies.state()
        XCTAssertEqual(message, StartRecordingDependencyError.reserve.localizedDescription)
        XCTAssertNil(reservation)
        XCTAssertEqual(invalidations, 0)
        XCTAssertEqual(
            state.events,
            ["preferences", "prepare", "count", "reserve", "cancel", "release"])
        XCTAssertNil(state.captureRequest)
    }

    func testSourceFailureWithoutEvidenceDiscardsOnlyEmptyShell() async {
        let fixture = StartRecordingFixture()
        let dependencies = StartRecordingDependencies(
            preferences: fixture.preferences,
            startError: .start)

        let result = await fixture.useCase(dependencies).execute(StartRecordingRequest())

        guard case .captureFailed(let message, let reservation, let invalidations) = result else {
            return XCTFail("source failure should be explicit")
        }
        let state = await dependencies.state()
        XCTAssertEqual(message, StartRecordingDependencyError.start.localizedDescription)
        XCTAssertNil(reservation)
        XCTAssertEqual(invalidations, 2)
        XCTAssertEqual(state.discardCount, 1)
        XCTAssertNil(state.markedErrorCode)
        XCTAssertEqual(state.releaseCount, 1)
        XCTAssertEqual(state.events.suffix(3), ["cancel", "discard", "release"])
    }

    func testSourceFailureAtEitherCapturePathPreservesRecoveryEvidence() async {
        let fixture = StartRecordingFixture()
        let staging = AudioCapturePath.stagingRelativePath(
            directory: fixture.directory,
            channel: .microphone)
        let published = AudioCapturePath.publishedRelativePath(
            directory: fixture.directory,
            channel: .microphone)

        for path in [staging, published] {
            let dependencies = StartRecordingDependencies(
                preferences: fixture.preferences,
                existingPaths: [path],
                startError: .start)

            let result = await fixture.useCase(dependencies).execute(StartRecordingRequest())

            guard case .captureFailed(_, let reservation?, let invalidations) = result else {
                return XCTFail("filesystem evidence should preserve the reservation")
            }
            let state = await dependencies.state()
            XCTAssertEqual(reservation.meeting.lifecycleState, .needsAttention)
            XCTAssertEqual(reservation.meeting.lastProcessingError, "capture.start.failed")
            XCTAssertEqual(invalidations, 2)
            XCTAssertEqual(state.markedErrorCode, "capture.start.failed")
            XCTAssertEqual(state.discardCount, 0)
        }
    }

    func testRefusedDiscardRetainsReservationAndAppendsReconciliationDetail() async {
        let fixture = StartRecordingFixture()
        let dependencies = StartRecordingDependencies(
            preferences: fixture.preferences,
            discardResult: false,
            startError: .start)

        let result = await fixture.useCase(dependencies).execute(StartRecordingRequest())

        guard case .captureFailed(let message, let reservation?, let invalidations) = result else {
            return XCTFail("a protected shell must remain discoverable")
        }
        XCTAssertTrue(message.hasSuffix(" · recording shell could not be reconciled"))
        XCTAssertEqual(reservation.meeting.lifecycleState, .recording)
        XCTAssertEqual(invalidations, 1)
    }

    func testReconciliationFailureNeverClaimsPreservedTransition() async {
        let fixture = StartRecordingFixture()
        let path = AudioCapturePath.stagingRelativePath(
            directory: fixture.directory,
            channel: .microphone)
        let dependencies = StartRecordingDependencies(
            preferences: fixture.preferences,
            existingPaths: [path],
            startError: .start,
            markError: .mark)

        let result = await fixture.useCase(dependencies).execute(StartRecordingRequest())

        guard case .captureFailed(let message, let reservation?, let invalidations) = result else {
            return XCTFail("failed reconciliation should retain original shell truth")
        }
        XCTAssertTrue(message.contains(StartRecordingDependencyError.mark.localizedDescription))
        XCTAssertEqual(reservation.meeting.lifecycleState, .recording)
        XCTAssertNil(reservation.meeting.lastProcessingError)
        XCTAssertEqual(invalidations, 1)
    }

    func testRealStoreAdapterAtomicallyReservesShellAndAssetsBeforeStart() async throws {
        let fixture = StartRecordingFixture()
        let store = try MeetingStore.inMemory()
        let dependencies = StartRecordingDependencies(preferences: fixture.preferences)
        let useCase = StartRecording(
            preferences: dependencies,
            audioFiles: dependencies,
            store: store,
            runtime: dependencies,
            makeMeetingID: { fixture.meetingID },
            now: { fixture.now },
            calendar: fixture.calendar)

        let result = await useCase.execute(StartRecordingRequest())

        guard case .started = result else {
            return XCTFail("real Store reservation should start")
        }
        let detail = try await store.detail(fixture.meetingID)
        let assets = try await store.audioAssets(for: fixture.meetingID)
        XCTAssertEqual(detail?.meeting.lifecycleState, .recording)
        XCTAssertEqual(assets.map(\.channel), [.microphone, .system])
        XCTAssertTrue(assets.allSatisfy { $0.healthStatus == .pending })
        let state = await dependencies.state()
        XCTAssertEqual(state.events, ["preferences", "prepare", "start"])
    }
}

private struct StartRecordingFixture {
    let meetingID = MeetingID(rawValue: UUID(
        uuidString: "91919191-9191-9191-9191-919191919191")!)
    let now = Date(timeIntervalSince1970: 1_783_695_660)
    var directory: String { "Audio/\(meetingID.rawValue.uuidString)" }
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    var preferences: StartRecordingPreferencesSnapshot {
        StartRecordingPreferencesSnapshot(
            titleTemplate: "{seq} Recording",
            titleLocaleIdentifier: "en_US",
            transcriptLanguage: .automatic,
            vocabulary: ["Portavoz", "Trinity"],
            voiceProcessingEnabled: true,
            preferredInputDeviceID: "preferred-mic",
            captureMode: .meetingApps)
    }

    func useCase(_ dependencies: StartRecordingDependencies) -> StartRecording {
        StartRecording(
            preferences: dependencies,
            audioFiles: dependencies,
            store: dependencies,
            runtime: dependencies,
            makeMeetingID: { meetingID },
            now: { now },
            calendar: calendar)
    }
}

private enum StartRecordingDependencyError: Error, LocalizedError {
    case prepare
    case reserve
    case start
    case mark

    var errorDescription: String? { "Start recording fixture failed: \(self)" }
}

private actor StartRecordingTestSession: StartRecordingSession {
    func stop() async -> StopRecordingCapture {
        StopRecordingCapture(publishedFiles: [:])
    }

    func voiceprint() async -> Voiceprint? { nil }
    func cancelVoiceprintRead() async {}
    nonisolated func setMicrophoneMuted(_ value: Bool) {}
}

private actor StartRecordingLiveProbe {
    struct State: Sendable {
        let captionCount: Int
        let chunkCount: Int
    }

    private var captionCount = 0
    private var chunkCount = 0

    func record(caption: TranscriptSegment) { captionCount += 1 }
    func record(chunk: AudioChunk) { chunkCount += 1 }
    func state() -> State { State(captionCount: captionCount, chunkCount: chunkCount) }
}

private actor StartRecordingDependencies:
    StartRecordingPreferences,
    StartRecordingAudioFiles,
    StartRecordingStore,
    StartRecordingRuntime {
    struct State: Sendable {
        let events: [String]
        let captureRequest: StartRecordingCaptureRequest?
        let reservedMeeting: Meeting?
        let markedErrorCode: String?
        let discardCount: Int
        let cancelCount: Int
        let releaseCount: Int
    }

    private let preferences: StartRecordingPreferencesSnapshot
    private let existingPaths: Set<String>
    private let startedMeetingCountValue: Int
    private let discardResult: Bool
    private let prepareError: StartRecordingDependencyError?
    private let liveTranscriptionAvailable: Bool
    private let reserveError: StartRecordingDependencyError?
    private let startError: StartRecordingDependencyError?
    private let markError: StartRecordingDependencyError?
    private var events: [String] = []
    private var captureRequest: StartRecordingCaptureRequest?
    private var reservedMeeting: Meeting?
    private var reservedAssets: [AudioAsset] = []
    private var markedErrorCode: String?
    private var discardCount = 0
    private var cancelCount = 0
    private var releaseCount = 0

    init(
        preferences: StartRecordingPreferencesSnapshot,
        existingPaths: Set<String> = [],
        startedMeetingCount: Int = 0,
        discardResult: Bool = true,
        prepareError: StartRecordingDependencyError? = nil,
        liveTranscriptionAvailable: Bool = true,
        reserveError: StartRecordingDependencyError? = nil,
        startError: StartRecordingDependencyError? = nil,
        markError: StartRecordingDependencyError? = nil
    ) {
        self.preferences = preferences
        self.existingPaths = existingPaths
        startedMeetingCountValue = startedMeetingCount
        self.discardResult = discardResult
        self.prepareError = prepareError
        self.liveTranscriptionAvailable = liveTranscriptionAvailable
        self.reserveError = reserveError
        self.startError = startError
        self.markError = markError
    }

    func startRecordingPreferences() async -> StartRecordingPreferencesSnapshot {
        events.append("preferences")
        return preferences
    }

    func prepare(
        preferences: StartRecordingPreferencesSnapshot
    ) async throws -> StartRecordingPreparedRuntime {
        events.append("prepare")
        if let prepareError { throw prepareError }
        return StartRecordingPreparedRuntime(
            channels: [.microphone, .system],
            tappedMeetingApps: ["Meet"],
            liveTranscriptionAvailable: liveTranscriptionAvailable)
    }

    func startCapture(
        _ request: StartRecordingCaptureRequest
    ) async throws -> any StartRecordingSession {
        events.append("start")
        captureRequest = request
        if let startError { throw startError }
        await request.callbacks.caption(TranscriptSegment(
            meetingID: request.meetingID,
            channel: .microphone,
            text: "La reunión comienza.",
            language: "es",
            startTime: 0,
            endTime: 1,
            isFinal: true))
        request.callbacks.chunk(AudioChunk(
            channel: .microphone,
            samples: [0.1],
            sampleRate: 48_000,
            timestamp: 0))
        return StartRecordingTestSession()
    }

    func cancelPreparation() async {
        cancelCount += 1
        events.append("cancel")
    }

    func scheduleIdleRelease() async {
        releaseCount += 1
        events.append("release")
    }

    func captureFileExists(relativePath: String) async -> Bool {
        existingPaths.contains(relativePath)
    }

    func startedMeetingCount(on date: Date, calendar: Calendar) async -> Int {
        events.append("count")
        return startedMeetingCountValue
    }

    func reserveRecording(_ meeting: Meeting, assets: [AudioAsset]) async throws {
        events.append("reserve")
        if let reserveError { throw reserveError }
        reservedMeeting = meeting
        reservedAssets = assets
    }

    func discardFailedRecordingStart(_ meetingID: MeetingID) async throws -> Bool {
        events.append("discard")
        discardCount += 1
        return discardResult
    }

    func markRecordingStartNeedsAttention(
        _ meetingID: MeetingID,
        endedAt: Date,
        at timestamp: Date
    ) async throws -> Meeting {
        events.append("mark")
        if let markError { throw markError }
        markedErrorCode = "capture.start.failed"
        var meeting = reservedMeeting!
        meeting.endedAt = endedAt
        meeting.lifecycleState = .needsAttention
        meeting.lastProcessingError = "capture.start.failed"
        return meeting
    }

    func state() -> State {
        State(
            events: events,
            captureRequest: captureRequest,
            reservedMeeting: reservedMeeting,
            markedErrorCode: markedErrorCode,
            discardCount: discardCount,
            cancelCount: cancelCount,
            releaseCount: releaseCount)
    }
}
