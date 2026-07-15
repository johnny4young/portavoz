import AudioCaptureKit
import Foundation
import OSLog
import PortavozCore
import StorageKit

/// Launch-time process manager for the filesystem/SQLite capture saga. It
/// deliberately performs no ML work: valid audio becomes discoverable first;
/// durable workers are adopted by the next Strangler slice.
@MainActor
enum RecordingRecoveryCoordinator {
    private static let logger = Logger(
        subsystem: "app.portavoz.mac", category: "recording-recovery")

    static func runIfNeeded(services: AppServices) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains(where: { $0.hasPrefix("--bench") }) else { return }

        var changed = false
        do {
            try await seedFixtureIfRequested(services: services, arguments: arguments)
        } catch {
            logger.error("Could not prepare recovery fixture: \(error.localizedDescription)")
        }
        do {
            let recoveredJobs = try await services.store.recoverExpiredProcessingJobs()
            changed = !recoveredJobs.isEmpty
        } catch {
            logger.error("Could not recover expired processing leases: \(error.localizedDescription)")
        }

        let meetings: [Meeting]
        do {
            meetings = try await services.store.meetings()
        } catch {
            logger.error("Could not load meetings for launch recovery: \(error.localizedDescription)")
            return
        }
        for meeting in meetings where meeting.lifecycleState != .ready {
            do {
                changed = try await reconcile(meeting, services: services) || changed
            } catch {
                await preserveFailure(error, for: meeting, services: services)
                changed = true
            }
        }
        if changed { services.libraryVersion += 1 }
    }

    private static func reconcile(
        _ meeting: Meeting,
        services: AppServices
    ) async throws -> Bool {
        guard !recordingPipelineIsActive(services.recording.phase) else { return false }
        let assets = try await services.store.audioAssets(for: meeting.id)
        var changed = false
        if meeting.lifecycleState == .recording
            || (meeting.lifecycleState == .needsAttention
                && meeting.lastProcessingError?.hasPrefix("capture.") == true) {
            changed = try await recoverCaptureShell(
                meeting, assets: assets, services: services)
        } else if assets.contains(where: { $0.healthStatus == .pending }) {
            let recovered = try await recoverPendingAssets(
                assets, directory: meeting.audioDirectory)
            try await services.store.installRecoveredCaptureAssets(
                recovered, for: meeting.id)
            changed = true
        }
        return try await reconcileInterruptedLifecycle(
            meeting.id, services: services) || changed
    }

    private static func recoverCaptureShell(
        _ meeting: Meeting,
        assets: [AudioAsset],
        services: AppServices
    ) async throws -> Bool {
        guard !assets.isEmpty, let directory = meeting.audioDirectory else {
            throw RecoveryError.invalidState
        }
        let recoveredPending = try await recoverPendingAssets(assets, directory: directory)
        let replacements = Dictionary(
            uniqueKeysWithValues: recoveredPending.map { ($0.id, $0) })
        let recoveredAssets = assets.map { replacements[$0.id] ?? $0 }
        guard recoveredAssets.contains(where: { isPublished($0.healthStatus) }) else {
            if meeting.lifecycleState == .recording,
                try await services.store.discardUnstartedRecording(meeting.id) {
                return true
            }
            if !recoveredPending.isEmpty {
                // A retained attention shell must not stay perpetually
                // pending when launch proved that its files are absent.
                try await services.store.installRecoveredCaptureAssets(
                    recoveredPending, for: meeting.id)
            }
            _ = try await services.store.markMeetingNeedsAttention(
                meeting.id,
                errorCode: "capture.recovery.missing",
                endedAt: meeting.startedAt)
            return true
        }

        var recoveredMeeting = meeting
        let duration = recoveredAssets.compactMap(\.durationSeconds).max() ?? 0
        recoveredMeeting.endedAt = meeting.startedAt.addingTimeInterval(duration)
        recoveredMeeting.lifecycleState = .needsAttention
        recoveredMeeting.lastProcessingError = "transcription.empty"
        do {
            try await services.store.installCapturedSnapshot(CapturedMeetingSnapshot(
                meeting: recoveredMeeting,
                assets: recoveredAssets,
                speakers: [],
                segments: [],
                contextItems: [],
                companionCards: []))
        } catch {
            guard meeting.lifecycleState == .needsAttention, !recoveredPending.isEmpty else {
                throw error
            }
            // A shell with already-persisted content is not replaced. Only
            // its still-pending assets are reconciled, in one transaction.
            try await services.store.installRecoveredCaptureAssets(
                recoveredPending, for: meeting.id)
        }
        return true
    }

    private static func reconcileInterruptedLifecycle(
        _ meetingID: MeetingID,
        services: AppServices
    ) async throws -> Bool {
        guard let detail = try await services.store.detail(meetingID) else { return false }
        let meeting = detail.meeting
        let jobs = try await services.store.processingJobs(for: meetingID)
        guard jobs.isEmpty else { return false }

        if meeting.lifecycleState == .captured || meeting.lifecycleState == .processing {
            let code = detail.segments.isEmpty
                ? "transcription.empty" : "processing.interrupted"
            _ = try await services.store.markMeetingNeedsAttention(
                meetingID, errorCode: code, endedAt: meeting.endedAt)
            return true
        }
        guard meeting.lifecycleState == .needsAttention,
            meeting.lastProcessingError?.hasPrefix("capture.") == true
        else { return false }

        let assets = try await services.store.audioAssets(for: meetingID)
        if meeting.lastProcessingError == "capture.publication.failed",
            !detail.segments.isEmpty,
            !assets.isEmpty,
            !assets.contains(where: { $0.healthStatus == .pending }) {
            // Re-submit exact terminal evidence to the repeat-safe Unit of
            // Work; it clears the publication-only error when no jobs exist.
            try await services.store.installRecoveredCaptureAssets(
                assets, for: meetingID)
            return true
        }
        if detail.segments.isEmpty,
            assets.contains(where: { isPublished($0.healthStatus) }) {
            _ = try await services.store.markMeetingNeedsAttention(
                meetingID,
                errorCode: "transcription.empty",
                endedAt: meeting.endedAt)
            return true
        }
        return false
    }

    private static func recoverPendingAssets(
        _ assets: [AudioAsset],
        directory: String?
    ) async throws -> [AudioAsset] {
        guard let directory else { throw RecoveryError.invalidState }
        let location = RecordingsLocation.shared
        var recovered: [AudioAsset] = []
        for asset in assets where asset.healthStatus == .pending {
            let evidence = try await Task.detached(priority: .utility) {
                try inspect(asset: asset, directory: directory, location: location)
            }.value
            recovered.append(apply(evidence, to: asset, directory: directory))
        }
        return recovered
    }

    private static func apply(
        _ evidence: FileEvidence,
        to reservation: AudioAsset,
        directory: String
    ) -> AudioAsset {
        var asset = reservation
        asset.updatedAt = Date()
        switch evidence {
        case .published(let file):
            asset.relativePath = AudioCapturePath.publishedRelativePath(
                directory: directory, channel: asset.channel)
            asset.container = file.container
            asset.codec = file.codec
            asset.sampleRate = file.sampleRate
            asset.channelCount = file.channelCount
            asset.durationSeconds = file.durationSeconds
            asset.byteCount = file.byteCount
            asset.sha256 = file.sha256
            asset.healthStatus = file.healthStatus
            asset.peakDBFS = file.peakDBFS
            asset.rmsDBFS = file.rmsDBFS
        case .missing:
            asset.healthStatus = .missing
        }
        return asset
    }

    private static func preserveFailure(
        _ error: Error,
        for meeting: Meeting,
        services: AppServices
    ) async {
        let code = (error as? RecoveryError)?.code ?? "capture.recovery.failed"
        do {
            _ = try await services.store.markMeetingNeedsAttention(
                meeting.id,
                errorCode: code,
                endedAt: meeting.endedAt ?? meeting.startedAt)
        } catch {
            logger.error(
                "Could not preserve interrupted meeting \(meeting.id.rawValue.uuidString): \(error.localizedDescription)")
        }
    }

    private static func seedFixtureIfRequested(
        services: AppServices,
        arguments: [String]
    ) async throws {
        guard arguments.contains("-seed-recovery") else { return }
        guard arguments.contains("-use-temp-store") else {
            throw RecoveryError.fixtureRequiresTemporaryStore
        }
        let meeting = Meeting(
            title: "Recovered recording",
            startedAt: Date(timeIntervalSince1970: 1_783_695_600),
            audioDirectory: "Audio/recovery-fixture",
            lifecycleState: .recording)
        let reservation = AudioAsset.pendingCapture(
            meetingID: meeting.id,
            channel: .microphone,
            relativePath: AudioCapturePath.stagingRelativePath(
                directory: "Audio/recovery-fixture", channel: .microphone),
            at: meeting.startedAt)
        try await services.store.beginRecording(meeting, assets: [reservation])

        let directory = RecordingsLocation.shared.currentRoot()
            .appendingPathComponent("Audio/recovery-fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let stagingURL = directory.appendingPathComponent(
            AudioCapturePath.stagingFilename(for: .microphone))
        try autoreleasepool {
            let writer = try CaptureFileWriter(url: stagingURL, sampleRate: 16_000)
            try writer.append([Float](repeating: 0.25, count: 16_000))
        }
    }

    private static func isPublished(_ health: AudioAssetHealthStatus) -> Bool {
        health == .healthy || health == .silent || health == .clipped
    }

    private static func recordingPipelineIsActive(
        _ phase: RecordingController.Phase
    ) -> Bool {
        switch phase {
        case .preparing, .recording, .processing: true
        case .idle, .done, .failed: false
        }
    }
}

private extension RecordingRecoveryCoordinator {
    enum FileEvidence: Sendable {
        case published(PublishedCaptureFile)
        case missing
    }

    enum RecoveryError: Error {
        case ambiguousFiles(AudioChannel)
        case invalidFile(AudioChannel)
        case invalidState
        case fixtureRequiresTemporaryStore

        var code: String {
            switch self {
            case .ambiguousFiles: "capture.recovery.ambiguous"
            case .invalidFile: "capture.recovery.invalid"
            case .invalidState: "capture.recovery.invalid-state"
            case .fixtureRequiresTemporaryStore: "capture.recovery.fixture-unsafe"
            }
        }
    }

    nonisolated static func inspect(
        asset: AudioAsset,
        directory: String,
        location: RecordingsLocation
    ) throws -> FileEvidence {
        let stagingPath = AudioCapturePath.stagingRelativePath(
            directory: directory, channel: asset.channel)
        let publishedPath = AudioCapturePath.publishedRelativePath(
            directory: directory, channel: asset.channel)
        let roots = uniqueRoots(location)
        let stagingFiles = existingURLs(relativePath: stagingPath, roots: roots)
        let publishedFiles = existingURLs(relativePath: publishedPath, roots: roots)
        guard stagingFiles.count <= 1, publishedFiles.count <= 1,
            stagingFiles.isEmpty || publishedFiles.isEmpty
        else { throw RecoveryError.ambiguousFiles(asset.channel) }

        do {
            if let stagingURL = stagingFiles.first {
                let finalURL = stagingURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        AudioCapturePath.publishedFilename(for: asset.channel))
                return .published(try CaptureFileRecovery.publish(
                    stagingURL: stagingURL, finalURL: finalURL))
            }
            if let publishedURL = publishedFiles.first {
                return .published(try CaptureFileRecovery.inspectPublishedFile(
                    at: publishedURL))
            }
            return .missing
        } catch let error as RecoveryError {
            throw error
        } catch {
            throw RecoveryError.invalidFile(asset.channel)
        }
    }

    nonisolated static func uniqueRoots(_ location: RecordingsLocation) -> [URL] {
        var paths: Set<String> = []
        return [location.currentRoot(), location.defaultRoot].filter {
            paths.insert($0.standardizedFileURL.path).inserted
        }
    }

    nonisolated static func existingURLs(
        relativePath: String,
        roots: [URL]
    ) -> [URL] {
        roots.map { $0.appendingPathComponent(relativePath) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
