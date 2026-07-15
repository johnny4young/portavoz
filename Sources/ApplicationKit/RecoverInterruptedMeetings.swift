import Foundation
import PortavozCore
import StorageKit

/// Minimal live aggregate projection needed by launch reconciliation.
public struct RecoverInterruptedMeetingState: Sendable {
    public let meeting: Meeting
    public let segments: [TranscriptSegment]

    public init(meeting: Meeting, segments: [TranscriptSegment]) {
        self.meeting = meeting
        self.segments = segments
    }
}

/// Storage operations that protect D40 recovery from stale or partial writes.
public protocol RecoverInterruptedMeetingsStore: Sendable {
    func recoverExpiredRecoveryJobs(at timestamp: Date) async throws -> Int
    func recoveryCandidates() async throws -> [Meeting]
    func recoveryAssets(for meetingID: MeetingID) async throws -> [AudioAsset]
    func recoveryState(for meetingID: MeetingID) async throws
        -> RecoverInterruptedMeetingState?
    func recoveryHasProcessingJobs(for meetingID: MeetingID) async throws -> Bool
    func discardRecoveryShell(_ meetingID: MeetingID) async throws -> Bool
    func installRecoveryAssets(
        _ assets: [AudioAsset],
        for meetingID: MeetingID,
        at timestamp: Date
    ) async throws
    func installRecoverySnapshot(
        _ snapshot: CapturedMeetingSnapshot,
        at timestamp: Date
    ) async throws
    func markRecoveryNeedsAttention(
        _ meetingID: MeetingID,
        errorCode: String,
        endedAt: Date,
        at timestamp: Date
    ) async throws -> Meeting
}

extension MeetingStore: RecoverInterruptedMeetingsStore {
    public func recoverExpiredRecoveryJobs(at timestamp: Date) async throws -> Int {
        try await recoverExpiredProcessingJobs(at: timestamp).count
    }

    public func recoveryCandidates() async throws -> [Meeting] {
        try await meetings().filter { $0.lifecycleState != .ready }
    }

    public func recoveryAssets(for meetingID: MeetingID) async throws -> [AudioAsset] {
        try await audioAssets(for: meetingID)
    }

    public func recoveryState(
        for meetingID: MeetingID
    ) async throws -> RecoverInterruptedMeetingState? {
        try await detail(meetingID).map {
            RecoverInterruptedMeetingState(meeting: $0.meeting, segments: $0.segments)
        }
    }

    public func recoveryHasProcessingJobs(for meetingID: MeetingID) async throws -> Bool {
        try await !processingJobs(for: meetingID).isEmpty
    }

    public func discardRecoveryShell(_ meetingID: MeetingID) async throws -> Bool {
        try await discardUnstartedRecording(meetingID)
    }

    public func installRecoveryAssets(
        _ assets: [AudioAsset],
        for meetingID: MeetingID,
        at timestamp: Date
    ) async throws {
        try await installRecoveredCaptureAssets(assets, for: meetingID, at: timestamp)
    }

    public func installRecoverySnapshot(
        _ snapshot: CapturedMeetingSnapshot,
        at timestamp: Date
    ) async throws {
        _ = try await installCapturedSnapshot(snapshot, at: timestamp)
    }

    public func markRecoveryNeedsAttention(
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
}

/// Platform-owned filesystem adapter. Each call must inspect every configured
/// and fallback root, publish staging-only evidence without overwrite, and
/// return complete validated metadata or explicit missing evidence.
public protocol RecoverInterruptedMeetingsFiles: Sendable {
    func recoverPendingAsset(
        _ asset: AudioAsset,
        directory: String,
        at timestamp: Date
    ) async throws -> AudioAsset
}

/// Dynamic gate sampled before each aggregate so recovery never races a live
/// writer that started while launch reconciliation was already in progress.
public protocol RecoverInterruptedMeetingsActivity: Sendable {
    func recordingPipelineIsActive() async -> Bool
}

public enum RecoverInterruptedMeetingError: Error, Equatable, LocalizedError, Sendable {
    case ambiguousCapture(AudioChannel)
    case invalidCapture(AudioChannel)
    case invalidState

    public var recoveryCode: String {
        switch self {
        case .ambiguousCapture: "capture.recovery.ambiguous"
        case .invalidCapture: "capture.recovery.invalid"
        case .invalidState: "capture.recovery.invalid-state"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .ambiguousCapture(let channel):
            "Ambiguous recovery evidence for the \(channel.rawValue) channel."
        case .invalidCapture(let channel):
            "Invalid recovery evidence for the \(channel.rawValue) channel."
        case .invalidState:
            "The interrupted recording does not have recoverable local state."
        }
    }
}

public struct RecoverInterruptedMeetingsRequest: Sendable {
    public init() {}
}

public enum RecoverInterruptedMeetingsIssueStage: Sendable, Equatable {
    case expiredLeaseRecovery
    case candidateLoading
    case failurePreservation(MeetingID)
}

public struct RecoverInterruptedMeetingsIssue: Sendable, Equatable {
    public let stage: RecoverInterruptedMeetingsIssueStage
    public let message: String

    public init(stage: RecoverInterruptedMeetingsIssueStage, message: String) {
        self.stage = stage
        self.message = message
    }
}

/// Launch-level report mapped to logging and broad invalidation by the app.
public struct RecoverInterruptedMeetingsResult: Sendable {
    public let recoveredLeaseCount: Int
    public let reconciledMeetingCount: Int
    public let preservedFailureCount: Int
    public let deferredMeetingCount: Int
    public let libraryInvalidationRequired: Bool
    public let issues: [RecoverInterruptedMeetingsIssue]

    public init(
        recoveredLeaseCount: Int,
        reconciledMeetingCount: Int,
        preservedFailureCount: Int,
        deferredMeetingCount: Int,
        libraryInvalidationRequired: Bool,
        issues: [RecoverInterruptedMeetingsIssue]
    ) {
        self.recoveredLeaseCount = recoveredLeaseCount
        self.reconciledMeetingCount = reconciledMeetingCount
        self.preservedFailureCount = preservedFailureCount
        self.deferredMeetingCount = deferredMeetingCount
        self.libraryInvalidationRequired = libraryInvalidationRequired
        self.issues = issues
    }
}

/// Reconciles expired leases and every interrupted live aggregate before the
/// process worker starts. It performs no transcription, diarization, summary,
/// or other ML work.
public struct RecoverInterruptedMeetings: ApplicationUseCase {
    private let store: any RecoverInterruptedMeetingsStore
    private let files: any RecoverInterruptedMeetingsFiles
    private let activity: any RecoverInterruptedMeetingsActivity
    private let now: @Sendable () -> Date

    public init(
        store: any RecoverInterruptedMeetingsStore,
        files: any RecoverInterruptedMeetingsFiles,
        activity: any RecoverInterruptedMeetingsActivity,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.files = files
        self.activity = activity
        self.now = now
    }

    public func execute(
        _ request: RecoverInterruptedMeetingsRequest
    ) async -> RecoverInterruptedMeetingsResult {
        _ = request
        let timestamp = now()
        let leaseRecovery = await recoverExpiredJobs(at: timestamp)
        let recoveredLeaseCount = leaseRecovery.count
        var issues = leaseRecovery.issue.map { [$0] } ?? []

        let candidates: [Meeting]
        do {
            candidates = try await store.recoveryCandidates()
        } catch {
            issues.append(RecoverInterruptedMeetingsIssue(
                stage: .candidateLoading,
                message: error.localizedDescription))
            // Preserve the released invalidation timing: a failed candidate
            // read exits before the broad Library refresh.
            return RecoverInterruptedMeetingsResult(
                recoveredLeaseCount: recoveredLeaseCount,
                reconciledMeetingCount: 0,
                preservedFailureCount: 0,
                deferredMeetingCount: 0,
                libraryInvalidationRequired: false,
                issues: issues)
        }

        var changed = recoveredLeaseCount > 0
        var reconciledMeetingCount = 0
        var preservedFailureCount = 0
        var deferredMeetingCount = 0
        for meeting in candidates {
            if await activity.recordingPipelineIsActive() {
                deferredMeetingCount += 1
                continue
            }
            do {
                if try await reconcile(meeting, timestamp: timestamp) {
                    changed = true
                    reconciledMeetingCount += 1
                }
            } catch {
                preservedFailureCount += 1
                do {
                    _ = try await store.markRecoveryNeedsAttention(
                        meeting.id,
                        errorCode: recoveryCode(for: error),
                        endedAt: meeting.endedAt ?? meeting.startedAt,
                        at: timestamp)
                } catch {
                    issues.append(RecoverInterruptedMeetingsIssue(
                        stage: .failurePreservation(meeting.id),
                        message: error.localizedDescription))
                }
                // The released coordinator refreshes after every failed
                // aggregate attempt, including a failed preservation write.
                changed = true
            }
        }

        return RecoverInterruptedMeetingsResult(
            recoveredLeaseCount: recoveredLeaseCount,
            reconciledMeetingCount: reconciledMeetingCount,
            preservedFailureCount: preservedFailureCount,
            deferredMeetingCount: deferredMeetingCount,
            libraryInvalidationRequired: changed,
            issues: issues)
    }

    private func recoverExpiredJobs(
        at timestamp: Date
    ) async -> (count: Int, issue: RecoverInterruptedMeetingsIssue?) {
        do {
            return (try await store.recoverExpiredRecoveryJobs(at: timestamp), nil)
        } catch {
            return (0, RecoverInterruptedMeetingsIssue(
                stage: .expiredLeaseRecovery,
                message: error.localizedDescription))
        }
    }

    private func reconcile(_ meeting: Meeting, timestamp: Date) async throws -> Bool {
        let assets = try await store.recoveryAssets(for: meeting.id)
        var changed = false
        if meeting.lifecycleState == .recording
            || (meeting.lifecycleState == .needsAttention
                && meeting.lastProcessingError?.hasPrefix("capture.") == true) {
            changed = try await recoverCaptureShell(
                meeting,
                assets: assets,
                timestamp: timestamp)
        } else if assets.contains(where: { $0.healthStatus == .pending }) {
            let recovered = try await recoverPendingAssets(
                assets,
                directory: meeting.audioDirectory,
                timestamp: timestamp)
            try await store.installRecoveryAssets(
                recovered,
                for: meeting.id,
                at: timestamp)
            changed = true
        }
        return try await reconcileInterruptedLifecycle(
            meeting.id,
            timestamp: timestamp) || changed
    }

    private func recoverCaptureShell(
        _ meeting: Meeting,
        assets: [AudioAsset],
        timestamp: Date
    ) async throws -> Bool {
        guard !assets.isEmpty, let directory = meeting.audioDirectory else {
            throw RecoverInterruptedMeetingError.invalidState
        }
        let recoveredPending = try await recoverPendingAssets(
            assets,
            directory: directory,
            timestamp: timestamp)
        let replacements = Dictionary(
            uniqueKeysWithValues: recoveredPending.map { ($0.id, $0) })
        let recoveredAssets = assets.map { replacements[$0.id] ?? $0 }
        guard recoveredAssets.contains(where: { isPublished($0.healthStatus) }) else {
            if meeting.lifecycleState == .recording,
                try await store.discardRecoveryShell(meeting.id) {
                return true
            }
            if !recoveredPending.isEmpty {
                try await store.installRecoveryAssets(
                    recoveredPending,
                    for: meeting.id,
                    at: timestamp)
            }
            _ = try await store.markRecoveryNeedsAttention(
                meeting.id,
                errorCode: "capture.recovery.missing",
                endedAt: meeting.startedAt,
                at: timestamp)
            return true
        }

        var recoveredMeeting = meeting
        let duration = recoveredAssets.compactMap(\.durationSeconds).max() ?? 0
        recoveredMeeting.endedAt = meeting.startedAt.addingTimeInterval(duration)
        recoveredMeeting.lifecycleState = .needsAttention
        recoveredMeeting.lastProcessingError = "transcription.empty"
        do {
            try await store.installRecoverySnapshot(
                CapturedMeetingSnapshot(
                    meeting: recoveredMeeting,
                    assets: recoveredAssets,
                    speakers: [],
                    segments: [],
                    contextItems: [],
                    companionCards: []),
                at: timestamp)
        } catch {
            guard meeting.lifecycleState == .needsAttention, !recoveredPending.isEmpty else {
                throw error
            }
            // Existing user content is never replaced. Only pending evidence
            // crosses the repeat-safe recovery transaction.
            try await store.installRecoveryAssets(
                recoveredPending,
                for: meeting.id,
                at: timestamp)
        }
        return true
    }

    private func reconcileInterruptedLifecycle(
        _ meetingID: MeetingID,
        timestamp: Date
    ) async throws -> Bool {
        guard let state = try await store.recoveryState(for: meetingID) else { return false }
        let meeting = state.meeting
        guard try await !store.recoveryHasProcessingJobs(for: meetingID) else { return false }

        if meeting.lifecycleState == .captured || meeting.lifecycleState == .processing {
            let code = state.segments.isEmpty
                ? "transcription.empty" : "processing.interrupted"
            _ = try await store.markRecoveryNeedsAttention(
                meetingID,
                errorCode: code,
                endedAt: meeting.endedAt ?? meeting.startedAt,
                at: timestamp)
            return true
        }
        guard meeting.lifecycleState == .needsAttention,
            meeting.lastProcessingError?.hasPrefix("capture.") == true
        else { return false }

        let assets = try await store.recoveryAssets(for: meetingID)
        if meeting.lastProcessingError == "capture.publication.failed",
            !state.segments.isEmpty,
            !assets.isEmpty,
            !assets.contains(where: { $0.healthStatus == .pending }) {
            try await store.installRecoveryAssets(assets, for: meetingID, at: timestamp)
            return true
        }
        if state.segments.isEmpty,
            assets.contains(where: { isPublished($0.healthStatus) }) {
            _ = try await store.markRecoveryNeedsAttention(
                meetingID,
                errorCode: "transcription.empty",
                endedAt: meeting.endedAt ?? meeting.startedAt,
                at: timestamp)
            return true
        }
        return false
    }

    private func recoverPendingAssets(
        _ assets: [AudioAsset],
        directory: String?,
        timestamp: Date
    ) async throws -> [AudioAsset] {
        guard let directory else { throw RecoverInterruptedMeetingError.invalidState }
        var recovered: [AudioAsset] = []
        for asset in assets where asset.healthStatus == .pending {
            recovered.append(try await files.recoverPendingAsset(
                asset,
                directory: directory,
                at: timestamp))
        }
        return recovered
    }

    private func recoveryCode(for error: Error) -> String {
        (error as? RecoverInterruptedMeetingError)?.recoveryCode
            ?? "capture.recovery.failed"
    }

    private func isPublished(_ health: AudioAssetHealthStatus) -> Bool {
        health == .healthy || health == .silent || health == .clipped
    }
}
