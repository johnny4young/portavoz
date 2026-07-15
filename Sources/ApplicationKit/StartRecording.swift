import DiarizationKit
import Foundation
import PortavozCore
import StorageKit

public enum StartRecordingCaptureMode: String, Sendable {
    case automatic
    case meetingApps
    case system
}

/// Platform preferences sampled once before a recording attempt begins.
public struct StartRecordingPreferencesSnapshot: Sendable {
    public let titleTemplate: String
    public let titleLocaleIdentifier: String
    public let transcriptLanguage: TranscriptLanguagePolicy
    public let vocabulary: [String]
    public let voiceProcessingEnabled: Bool
    public let preferredInputDeviceID: String?
    public let captureMode: StartRecordingCaptureMode

    public init(
        titleTemplate: String,
        titleLocaleIdentifier: String,
        transcriptLanguage: TranscriptLanguagePolicy,
        vocabulary: [String],
        voiceProcessingEnabled: Bool,
        preferredInputDeviceID: String?,
        captureMode: StartRecordingCaptureMode
    ) {
        self.titleTemplate = titleTemplate
        self.titleLocaleIdentifier = titleLocaleIdentifier
        self.transcriptLanguage = transcriptLanguage
        self.vocabulary = vocabulary
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.preferredInputDeviceID = preferredInputDeviceID
        self.captureMode = captureMode
    }
}

public protocol StartRecordingPreferences: Sendable {
    func startRecordingPreferences() async -> StartRecordingPreferencesSnapshot
}

public typealias StartRecordingCaptionHandler =
    @Sendable (TranscriptSegment) async -> Void
public typealias StartRecordingChunkHandler =
    @Sendable (AudioChunk) -> Void

/// Live callbacks stay presentation-owned while the runtime owns stream
/// setup and teardown. ApplicationKit never receives a concrete audio source.
public struct StartRecordingLiveCallbacks: Sendable {
    public let caption: StartRecordingCaptionHandler
    public let chunk: StartRecordingChunkHandler

    public init(
        caption: @escaping StartRecordingCaptionHandler = { _ in },
        chunk: @escaping StartRecordingChunkHandler = { _ in }
    ) {
        self.caption = caption
        self.chunk = chunk
    }
}

/// Structural sources selected by the platform runtime after model and mic
/// preparation. Display names are informational presentation evidence.
public struct StartRecordingPreparedRuntime: Sendable {
    public let channels: [AudioChannel]
    public let tappedMeetingApps: [String]

    public init(channels: [AudioChannel], tappedMeetingApps: [String] = []) {
        self.channels = channels
        self.tappedMeetingApps = tappedMeetingApps
    }
}

public struct StartRecordingCaptureRequest: Sendable {
    public let meetingID: MeetingID
    public let audioDirectory: String
    public let languageHint: String?
    public let vocabulary: [String]
    public let callbacks: StartRecordingLiveCallbacks

    public init(
        meetingID: MeetingID,
        audioDirectory: String,
        languageHint: String?,
        vocabulary: [String],
        callbacks: StartRecordingLiveCallbacks
    ) {
        self.meetingID = meetingID
        self.audioDirectory = audioDirectory
        self.languageHint = languageHint
        self.vocabulary = vocabulary
        self.callbacks = callbacks
    }
}

/// Opaque active capture returned to presentation. Its implementation owns
/// the concrete session, transcription feeds, microphone, and one voiceprint
/// future shared by live diarization and durable Stop.
public protocol StartRecordingSession: Sendable {
    func stop() async -> StopRecordingCapture
    func voiceprint() async -> Voiceprint?
    func cancelVoiceprintRead() async
    func setMicrophoneMuted(_ value: Bool)
}

/// Concrete capture/model ownership remains in the app composition adapter.
public protocol StartRecordingRuntime: Sendable {
    func prepare(
        preferences: StartRecordingPreferencesSnapshot
    ) async throws -> StartRecordingPreparedRuntime
    func startCapture(
        _ request: StartRecordingCaptureRequest
    ) async throws -> any StartRecordingSession
    func cancelPreparation() async
    func scheduleIdleRelease() async
}

public protocol StartRecordingAudioFiles: Sendable {
    func captureFileExists(relativePath: String) async -> Bool
}

/// Narrow persistence boundary for reservation and D37 reconciliation.
public protocol StartRecordingStore: Sendable {
    func startedMeetingCount(on date: Date, calendar: Calendar) async -> Int
    func reserveRecording(_ meeting: Meeting, assets: [AudioAsset]) async throws
    func discardFailedRecordingStart(_ meetingID: MeetingID) async throws -> Bool
    func markRecordingStartNeedsAttention(
        _ meetingID: MeetingID,
        endedAt: Date,
        at timestamp: Date
    ) async throws -> Meeting
}

extension MeetingStore: StartRecordingStore {
    public func startedMeetingCount(on date: Date, calendar: Calendar) async -> Int {
        ((try? await meetings()) ?? [])
            .filter { calendar.isDate($0.startedAt, inSameDayAs: date) }
            .count
    }

    public func reserveRecording(_ meeting: Meeting, assets: [AudioAsset]) async throws {
        try await beginRecording(meeting, assets: assets)
    }

    public func discardFailedRecordingStart(_ meetingID: MeetingID) async throws -> Bool {
        try await discardUnstartedRecording(meetingID)
    }

    public func markRecordingStartNeedsAttention(
        _ meetingID: MeetingID,
        endedAt: Date,
        at timestamp: Date
    ) async throws -> Meeting {
        try await markMeetingNeedsAttention(
            meetingID,
            errorCode: "capture.start.failed",
            endedAt: endedAt,
            at: timestamp)
    }
}

public enum StartRecordingRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case transcriptionEngineUnavailable
    case preparationUnavailable

    public var errorDescription: String? {
        switch self {
        case .transcriptionEngineUnavailable:
            "The transcription engine is not available."
        case .preparationUnavailable:
            "The prepared recording runtime is no longer available."
        }
    }
}

public struct StartRecordingRequest: Sendable {
    public let eventTitle: String?
    public let callbacks: StartRecordingLiveCallbacks

    public init(
        eventTitle: String? = nil,
        callbacks: StartRecordingLiveCallbacks = StartRecordingLiveCallbacks()
    ) {
        self.eventTitle = eventTitle
        self.callbacks = callbacks
    }
}

/// Durable reservation projection retained by the controller and later Stop.
public struct StartRecordingReservation: Sendable {
    public let meeting: Meeting
    public let assets: [AudioAsset]

    public init(meeting: Meeting, assets: [AudioAsset]) {
        self.meeting = meeting
        self.assets = assets
    }
}

public struct StartRecordingCommit: Sendable {
    public let reservation: StartRecordingReservation
    public let session: any StartRecordingSession
    public let tappedMeetingApps: [String]

    public init(
        reservation: StartRecordingReservation,
        session: any StartRecordingSession,
        tappedMeetingApps: [String]
    ) {
        self.reservation = reservation
        self.session = session
        self.tappedMeetingApps = tappedMeetingApps
    }
}

/// Typed outcomes keep localized copy and broad view invalidation outside the
/// workflow while preserving the released failure distinctions.
public enum StartRecordingResult: Sendable {
    case started(StartRecordingCommit)
    case modelPreparationFailed(message: String)
    case transcriptionEngineUnavailable
    case captureFailed(
        message: String,
        reservation: StartRecordingReservation?,
        libraryInvalidations: Int
    )
}

/// Prepares the platform runtime, reserves the discoverable aggregate before
/// any source starts, and reconciles a failed source start against filesystem
/// evidence. Live UI policy remains in the controller.
public struct StartRecording: ApplicationUseCase {
    private let preferences: any StartRecordingPreferences
    private let audioFiles: any StartRecordingAudioFiles
    private let store: any StartRecordingStore
    private let runtime: any StartRecordingRuntime
    private let makeMeetingID: @Sendable () -> MeetingID
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    public init(
        preferences: any StartRecordingPreferences,
        audioFiles: any StartRecordingAudioFiles,
        store: any StartRecordingStore,
        runtime: any StartRecordingRuntime,
        makeMeetingID: @escaping @Sendable () -> MeetingID = { MeetingID() },
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.preferences = preferences
        self.audioFiles = audioFiles
        self.store = store
        self.runtime = runtime
        self.makeMeetingID = makeMeetingID
        self.now = now
        self.calendar = calendar
    }

    public func execute(_ request: StartRecordingRequest) async -> StartRecordingResult {
        let sampledPreferences = await preferences.startRecordingPreferences()
        switch await prepareRuntime(sampledPreferences) {
        case .failed(let result):
            return result
        case .ready(let prepared):
            return await reserveAndStart(
                request,
                preferences: sampledPreferences,
                prepared: prepared)
        }
    }

    private func prepareRuntime(
        _ preferences: StartRecordingPreferencesSnapshot
    ) async -> StartRecordingPreparation {
        do {
            return .ready(try await runtime.prepare(preferences: preferences))
        } catch StartRecordingRuntimeError.transcriptionEngineUnavailable {
            await runtime.cancelPreparation()
            await runtime.scheduleIdleRelease()
            return .failed(.transcriptionEngineUnavailable)
        } catch {
            await runtime.cancelPreparation()
            await runtime.scheduleIdleRelease()
            return .failed(.modelPreparationFailed(message: error.localizedDescription))
        }
    }

    private func reserveAndStart(
        _ request: StartRecordingRequest,
        preferences: StartRecordingPreferencesSnapshot,
        prepared: StartRecordingPreparedRuntime
    ) async -> StartRecordingResult {
        let reservation = await makeReservation(
            eventTitle: request.eventTitle,
            preferences: preferences,
            channels: prepared.channels)
        do {
            try await store.reserveRecording(
                reservation.meeting,
                assets: reservation.assets)
        } catch {
            await runtime.cancelPreparation()
            await runtime.scheduleIdleRelease()
            return .captureFailed(
                message: error.localizedDescription,
                reservation: nil,
                libraryInvalidations: 0)
        }

        do {
            let session = try await runtime.startCapture(StartRecordingCaptureRequest(
                meetingID: reservation.meeting.id,
                audioDirectory: reservation.meeting.audioDirectory ?? "",
                languageHint: preferences.transcriptLanguage.languageHint,
                vocabulary: preferences.vocabulary,
                callbacks: request.callbacks))
            return .started(StartRecordingCommit(
                reservation: reservation,
                session: session,
                tappedMeetingApps: prepared.tappedMeetingApps))
        } catch {
            await runtime.cancelPreparation()
            let captureMessage = error.localizedDescription
            let reconciliation = await reconcileFailedStart(
                reservation,
                timestamp: now())
            await runtime.scheduleIdleRelease()
            let message = reconciliation.message.map {
                "\(captureMessage) · \($0)"
            } ?? captureMessage
            return .captureFailed(
                message: message,
                reservation: reconciliation.reservation,
                libraryInvalidations: reconciliation.libraryInvalidations)
        }
    }

    private func makeReservation(
        eventTitle: String?,
        preferences: StartRecordingPreferencesSnapshot,
        channels: [AudioChannel]
    ) async -> StartRecordingReservation {
        let startedAt = now()
        let meetingID = makeMeetingID()
        let audioDirectory = "Audio/\(meetingID.rawValue.uuidString)"
        let todayCount = await store.startedMeetingCount(
            on: startedAt,
            calendar: calendar)
        let title = eventTitle.map {
            TitleTemplate.eventTitle($0, date: startedAt)
        } ?? TitleTemplate.render(
            preferences.titleTemplate,
            date: startedAt,
            sequence: todayCount + 1,
            locale: Locale(identifier: preferences.titleLocaleIdentifier))
        let meeting = Meeting(
            id: meetingID,
            title: title,
            startedAt: startedAt,
            audioDirectory: audioDirectory,
            retention: .keep,
            lifecycleState: .recording)
        let assets = channels.map {
            AudioAsset.pendingCapture(
                meetingID: meetingID,
                channel: $0,
                relativePath: AudioCapturePath.stagingRelativePath(
                    directory: audioDirectory,
                    channel: $0),
                at: startedAt)
        }
        return StartRecordingReservation(meeting: meeting, assets: assets)
    }

    private func reconcileFailedStart(
        _ reservation: StartRecordingReservation,
        timestamp: Date
    ) async -> StartRecordingReconciliation {
        if await hasCaptureFile(for: reservation) {
            do {
                let meeting = try await store.markRecordingStartNeedsAttention(
                    reservation.meeting.id,
                    endedAt: timestamp,
                    at: timestamp)
                return StartRecordingReconciliation(
                    reservation: StartRecordingReservation(
                        meeting: meeting,
                        assets: reservation.assets),
                    libraryInvalidations: 2)
            } catch {
                return StartRecordingReconciliation(
                    reservation: reservation,
                    libraryInvalidations: 1,
                    message: error.localizedDescription)
            }
        }

        do {
            guard try await store.discardFailedRecordingStart(reservation.meeting.id) else {
                return StartRecordingReconciliation(
                    reservation: reservation,
                    libraryInvalidations: 1,
                    message: "recording shell could not be reconciled")
            }
            return StartRecordingReconciliation(
                reservation: nil,
                libraryInvalidations: 2)
        } catch {
            return StartRecordingReconciliation(
                reservation: reservation,
                libraryInvalidations: 1,
                message: error.localizedDescription)
        }
    }

    private func hasCaptureFile(for reservation: StartRecordingReservation) async -> Bool {
        guard let directory = reservation.meeting.audioDirectory else { return false }
        for asset in reservation.assets {
            if await audioFiles.captureFileExists(relativePath: asset.relativePath) {
                return true
            }
            if await audioFiles.captureFileExists(
                relativePath: AudioCapturePath.publishedRelativePath(
                    directory: directory,
                    channel: asset.channel)) {
                return true
            }
        }
        return false
    }
}

private struct StartRecordingReconciliation: Sendable {
    let reservation: StartRecordingReservation?
    let libraryInvalidations: Int
    let message: String?

    init(
        reservation: StartRecordingReservation?,
        libraryInvalidations: Int,
        message: String? = nil
    ) {
        self.reservation = reservation
        self.libraryInvalidations = libraryInvalidations
        self.message = message
    }
}

private enum StartRecordingPreparation: Sendable {
    case ready(StartRecordingPreparedRuntime)
    case failed(StartRecordingResult)
}
