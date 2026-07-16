import DiarizationKit
import Foundation
import PortavozCore
import StorageKit
import TranscriptionKit

/// Finalized media evidence produced by the platform capture adapter.
/// ApplicationKit never receives file handles or concrete capture sessions.
public struct StopRecordingPublishedFile: Sendable {
    public let container: String
    public let codec: String
    public let sampleRate: Double
    public let channelCount: Int
    public let durationSeconds: TimeInterval
    public let byteCount: Int64
    public let sha256: String
    public let healthStatus: AudioAssetHealthStatus
    public let peakDBFS: Double
    public let rmsDBFS: Double

    public init(
        container: String,
        codec: String,
        sampleRate: Double,
        channelCount: Int,
        durationSeconds: TimeInterval,
        byteCount: Int64,
        sha256: String,
        healthStatus: AudioAssetHealthStatus,
        peakDBFS: Double,
        rmsDBFS: Double
    ) {
        self.container = container
        self.codec = codec
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.durationSeconds = durationSeconds
        self.byteCount = byteCount
        self.sha256 = sha256
        self.healthStatus = healthStatus
        self.peakDBFS = peakDBFS
        self.rmsDBFS = rmsDBFS
    }
}

/// Reader-visible channels that passed inspection and atomic publication.
public struct StopRecordingCapture: Sendable {
    public let publishedFiles: [AudioChannel: StopRecordingPublishedFile]
    /// True when one or more live lanes were unavailable or failed. Stop must
    /// recover the complete transcript from finalized audio, even if another
    /// lane emitted a partial live transcript.
    public let transcriptRequiresRecovery: Bool

    public init(
        publishedFiles: [AudioChannel: StopRecordingPublishedFile],
        transcriptRequiresRecovery: Bool = false
    ) {
        self.publishedFiles = publishedFiles
        self.transcriptRequiresRecovery = transcriptRequiresRecovery
    }
}

/// Filesystem evidence needed only for unpublished reservation fallbacks.
public protocol StopRecordingAudioFiles: Sendable {
    func captureFileExists(relativePath: String) async -> Bool
}

/// Narrow storage boundary for the D43 captured aggregate handoff.
public protocol StopRecordingStore: Sendable {
    func discardUnstartedRecording(_ meetingID: MeetingID) async throws -> Bool
    func markStoppedMeetingNeedsAttention(
        _ meetingID: MeetingID,
        errorCode: String,
        endedAt: Date,
        at timestamp: Date
    ) async throws -> Meeting
    func installStoppedSnapshot(
        _ snapshot: CapturedMeetingSnapshot,
        enqueue requests: [ProcessingJobRequest]
    ) async throws
}

extension MeetingStore: StopRecordingStore {
    public func markStoppedMeetingNeedsAttention(
        _ meetingID: MeetingID,
        errorCode: String,
        endedAt: Date,
        at timestamp: Date
    ) async throws -> Meeting {
        try await markMeetingNeedsAttention(
            meetingID,
            errorCode: errorCode,
            endedAt: endedAt,
            at: timestamp)
    }

    public func installStoppedSnapshot(
        _ snapshot: CapturedMeetingSnapshot,
        enqueue requests: [ProcessingJobRequest]
    ) async throws {
        _ = try await installCapturedSnapshot(snapshot, enqueue: requests)
    }
}

/// Process-level effects that remain platform-composed but workflow-owned.
public protocol StopRecordingLifecycle: Sendable {
    func kickPostCaptureProcessing() async
    func scheduleRecordingEngineRelease() async
}

public struct StopRecordingRequest: Sendable {
    public let recordingShell: Meeting?
    public let reservedAssets: [AudioAsset]
    public let captions: [TranscriptSegment]
    public let contextItems: [ContextItem]
    public let companionCards: [CompanionCard]
    public let companionArtifacts: [CompanionGenerationArtifact]
    public let companionTerminalRuns: [GenerationRun]
    public let capture: StopRecordingCapture
    public let voiceprint: Voiceprint?

    public init(
        recordingShell: Meeting?,
        reservedAssets: [AudioAsset],
        captions: [TranscriptSegment],
        contextItems: [ContextItem],
        companionCards: [CompanionCard],
        companionArtifacts: [CompanionGenerationArtifact] = [],
        companionTerminalRuns: [GenerationRun] = [],
        capture: StopRecordingCapture,
        voiceprint: Voiceprint?
    ) {
        self.recordingShell = recordingShell
        self.reservedAssets = reservedAssets
        self.captions = captions
        self.contextItems = contextItems
        self.companionCards = companionCards
        self.companionArtifacts = companionArtifacts
        self.companionTerminalRuns = companionTerminalRuns
        self.capture = capture
        self.voiceprint = voiceprint
    }
}

/// Durable state that presentation mirrors after one successful mutation.
public struct StopRecordingCommit: Sendable {
    public let meeting: Meeting
    public let assets: [AudioAsset]

    public init(meeting: Meeting, assets: [AudioAsset]) {
        self.meeting = meeting
        self.assets = assets
    }
}

/// Explicit outcomes preserve the released user-visible failure policy while
/// keeping localized copy outside ApplicationKit.
public enum StopRecordingResult: Sendable {
    case completed(StopRecordingCommit)
    case audioRecoveryPreserved(StopRecordingCommit)
    case transcriptEmpty(StopRecordingCommit)
    case noAudioCaptured
    case localStateUnavailable
    case processingFailed(message: String, fallback: StopRecordingCommit?)
}

public enum StopRecordingJobError: Error, Equatable, LocalizedError, Sendable {
    case emptyTranscript
    case inputNotReady

    public var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            "The captured meeting has no transcript to process."
        case .inputNotReady:
            "The processing input does not have final durable evidence."
        }
    }
}

/// Owns exact initial operation identity and retry policy for captured audio.
public enum StopRecordingJobFactory {
    public static func initialTranscriptionRequest(
        meeting: Meeting,
        assets: [AudioAsset]
    ) -> ProcessingJobRequest? {
        InitialTranscriptionOperationFingerprint.request(
            meetingID: meeting.id,
            transcriptRevision: meeting.transcriptRevision,
            assets: assets)
    }

    public static func initialDiarizationRequest(
        meeting: Meeting,
        segments: [TranscriptSegment],
        assets: [AudioAsset],
        voiceprint: Voiceprint?
    ) throws -> ProcessingJobRequest {
        guard !segments.isEmpty else { throw StopRecordingJobError.emptyTranscript }
        guard let request = DiarizationOperationFingerprint.request(
            meetingID: meeting.id,
            transcriptRevision: meeting.transcriptRevision,
            segments: segments,
            systemAsset: currentSystemCapture(in: assets),
            voiceprint: voiceprint)
        else { throw StopRecordingJobError.inputNotReady }
        return request
    }

    private static func currentSystemCapture(in assets: [AudioAsset]) -> AudioAsset? {
        assets
            .filter {
                $0.channel == .system && $0.role == .capture
                    && $0.supersededAt == nil && $0.deletedAt == nil
            }
            .max { $0.updatedAt < $1.updatedAt }
    }
}

/// Installs the final captured truth and admits its first durable operation.
/// Capture/session teardown stays in the controller; every persistence and
/// failure-policy decision after publication crosses this boundary.
public struct StopRecording: ApplicationUseCase {
    private let audioFiles: any StopRecordingAudioFiles
    private let store: any StopRecordingStore
    private let lifecycle: any StopRecordingLifecycle
    private let now: @Sendable () -> Date

    public init(
        audioFiles: any StopRecordingAudioFiles,
        store: any StopRecordingStore,
        lifecycle: any StopRecordingLifecycle,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.audioFiles = audioFiles
        self.store = store
        self.lifecycle = lifecycle
        self.now = now
    }

    public func execute(_ request: StopRecordingRequest) async -> StopRecordingResult {
        let result = await install(request, timestamp: now())
        await lifecycle.scheduleRecordingEngineRelease()
        return result
    }

    private func install(
        _ request: StopRecordingRequest,
        timestamp: Date
    ) async -> StopRecordingResult {
        guard var meeting = request.recordingShell else {
            return .localStateUnavailable
        }
        guard let audioDirectory = meeting.audioDirectory else {
            return .localStateUnavailable
        }

        guard !request.capture.publishedFiles.isEmpty else {
            return await reconcileEmptyCapture(
                meeting: meeting,
                assets: request.reservedAssets,
                audioDirectory: audioDirectory,
                timestamp: timestamp)
        }

        meeting.endedAt = timestamp
        meeting.lifecycleState = .captured
        meeting.lastProcessingError = nil
        let attribution = SpeakerAttributor.attribute(
            segments: request.captions,
            turns: [],
            meetingID: meeting.id)
        meeting.language = SpokenLanguageDetector.homogeneousLanguage(
            in: attribution.segments)
        let assets = await reconciledAssets(
            request.reservedAssets,
            published: request.capture.publishedFiles,
            audioDirectory: audioDirectory,
            timestamp: timestamp)
        return await installPublishedCapture(
            request,
            meeting: meeting,
            assets: assets,
            attribution: attribution)
    }

    private func installPublishedCapture(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution
    ) async -> StopRecordingResult {
        if request.capture.transcriptRequiresRecovery || request.captions.isEmpty,
            let transcription = StopRecordingJobFactory.initialTranscriptionRequest(
                meeting: meeting,
                assets: assets) {
            return await installRecoverableTranscript(
                request,
                meeting: meeting,
                assets: assets,
                attribution: attribution,
                initialRequest: transcription)
        }
        guard !request.captions.isEmpty else {
            return await installEmptyTranscript(
                request,
                meeting: meeting,
                assets: assets,
                attribution: attribution)
        }

        let hasPendingPublication = assets.contains { $0.healthStatus == .pending }
        let initialRequest: ProcessingJobRequest
        do {
            initialRequest = try StopRecordingJobFactory.initialDiarizationRequest(
                meeting: meeting,
                segments: attribution.segments,
                assets: assets,
                voiceprint: request.voiceprint)
        } catch {
            let fallback = await preserveNeedsAttention(
                request,
                meeting: meeting,
                assets: assets,
                attribution: attribution,
                errorCode: hasPendingPublication
                    ? "capture.publication.failed" : "processing.enqueue.failed")
            return .processingFailed(
                message: error.localizedDescription,
                fallback: fallback)
        }

        return await installInitialDiarization(
            request,
            meeting: meeting,
            assets: assets,
            attribution: attribution,
            initialRequest: initialRequest,
            failureCode: hasPendingPublication
                ? "capture.publication.failed" : "processing.enqueue.failed")
    }

    private func installInitialDiarization(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution,
        initialRequest: ProcessingJobRequest,
        failureCode: String
    ) async -> StopRecordingResult {
        do {
            try await store.installStoppedSnapshot(
                capturedSnapshot(
                    request,
                    meeting: meeting,
                    assets: assets,
                    attribution: attribution),
                enqueue: [initialRequest])
            var processingMeeting = meeting
            processingMeeting.lifecycleState = .processing
            let commit = StopRecordingCommit(meeting: processingMeeting, assets: assets)
            await lifecycle.kickPostCaptureProcessing()
            return .completed(commit)
        } catch {
            let fallback = await preserveNeedsAttention(
                request,
                meeting: meeting,
                assets: assets,
                attribution: attribution,
                errorCode: failureCode)
            return .processingFailed(
                message: error.localizedDescription,
                fallback: fallback)
        }
    }

    private func installRecoverableTranscript(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution,
        initialRequest: ProcessingJobRequest
    ) async -> StopRecordingResult {
        do {
            try await store.installStoppedSnapshot(
                capturedSnapshot(
                    request,
                    meeting: meeting,
                    assets: assets,
                    attribution: attribution),
                enqueue: [initialRequest])
            var processingMeeting = meeting
            processingMeeting.lifecycleState = .processing
            let commit = StopRecordingCommit(meeting: processingMeeting, assets: assets)
            await lifecycle.kickPostCaptureProcessing()
            return .completed(commit)
        } catch {
            let fallback = await preserveNeedsAttention(
                request,
                meeting: meeting,
                assets: assets,
                attribution: attribution,
                errorCode: "processing.transcription.enqueue.failed")
            return .processingFailed(
                message: error.localizedDescription,
                fallback: fallback)
        }
    }

    private func installEmptyTranscript(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution
    ) async -> StopRecordingResult {
        var fallback = meeting
        fallback.lifecycleState = .needsAttention
        fallback.lastProcessingError = "transcription.empty"
        do {
            try await store.installStoppedSnapshot(
                capturedSnapshot(
                    request,
                    meeting: fallback,
                    assets: assets,
                    attribution: attribution),
                enqueue: [])
            return .transcriptEmpty(
                StopRecordingCommit(meeting: fallback, assets: assets))
        } catch {
            return .processingFailed(message: error.localizedDescription, fallback: nil)
        }
    }

    private func reconcileEmptyCapture(
        meeting: Meeting,
        assets: [AudioAsset],
        audioDirectory: String,
        timestamp: Date
    ) async -> StopRecordingResult {
        if await hasReservedCaptureFile(assets, audioDirectory: audioDirectory) {
            do {
                let preserved = try await store.markStoppedMeetingNeedsAttention(
                    meeting.id,
                    errorCode: "capture.publication.failed",
                    endedAt: timestamp,
                    at: timestamp)
                return .audioRecoveryPreserved(
                    StopRecordingCommit(meeting: preserved, assets: assets))
            } catch {
                return .processingFailed(message: error.localizedDescription, fallback: nil)
            }
        }

        do {
            guard try await store.discardUnstartedRecording(meeting.id) else {
                return .localStateUnavailable
            }
            return .noAudioCaptured
        } catch {
            return .processingFailed(message: error.localizedDescription, fallback: nil)
        }
    }

    private func preserveNeedsAttention(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution,
        errorCode: String
    ) async -> StopRecordingCommit? {
        var fallback = meeting
        fallback.lifecycleState = .needsAttention
        fallback.lastProcessingError = errorCode
        do {
            try await store.installStoppedSnapshot(
                capturedSnapshot(
                    request,
                    meeting: fallback,
                    assets: assets,
                    attribution: attribution),
                enqueue: [])
            return StopRecordingCommit(meeting: fallback, assets: assets)
        } catch {
            return nil
        }
    }

    private func capturedSnapshot(
        _ request: StopRecordingRequest,
        meeting: Meeting,
        assets: [AudioAsset],
        attribution: SpeakerAttributor.Attribution
    ) -> CapturedMeetingSnapshot {
        let generatedCardIDs = Set(request.companionArtifacts.map(\.card.id))
        return CapturedMeetingSnapshot(
            meeting: meeting,
            assets: assets,
            speakers: attribution.speakers,
            segments: attribution.segments,
            contextItems: request.contextItems,
            companionCards: request.companionCards.filter {
                !generatedCardIDs.contains($0.id)
            },
            companionArtifacts: request.companionArtifacts,
            companionTerminalRuns: request.companionTerminalRuns)
    }

    private func reconciledAssets(
        _ reservations: [AudioAsset],
        published: [AudioChannel: StopRecordingPublishedFile],
        audioDirectory: String,
        timestamp: Date
    ) async -> [AudioAsset] {
        var reconciled: [AudioAsset] = []
        for reservation in reservations {
            var asset = reservation
            asset.updatedAt = timestamp
            guard let evidence = published[asset.channel] else {
                if !(await audioFiles.captureFileExists(relativePath: asset.relativePath)) {
                    asset.healthStatus = .missing
                }
                reconciled.append(asset)
                continue
            }
            asset.relativePath = AudioCapturePath.publishedRelativePath(
                directory: audioDirectory,
                channel: asset.channel)
            asset.container = evidence.container
            asset.codec = evidence.codec
            asset.sampleRate = evidence.sampleRate
            asset.channelCount = evidence.channelCount
            asset.durationSeconds = evidence.durationSeconds
            asset.byteCount = evidence.byteCount
            asset.sha256 = evidence.sha256
            asset.healthStatus = evidence.healthStatus
            asset.peakDBFS = evidence.peakDBFS
            asset.rmsDBFS = evidence.rmsDBFS
            reconciled.append(asset)
        }
        return reconciled
    }

    private func hasReservedCaptureFile(
        _ assets: [AudioAsset],
        audioDirectory: String
    ) async -> Bool {
        for asset in assets {
            if await audioFiles.captureFileExists(relativePath: asset.relativePath) {
                return true
            }
            let published = AudioCapturePath.publishedRelativePath(
                directory: audioDirectory,
                channel: asset.channel)
            if await audioFiles.captureFileExists(relativePath: published) {
                return true
            }
        }
        return false
    }
}
