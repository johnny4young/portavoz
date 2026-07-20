import ApplicationKit
import AudioCaptureKit
import Foundation
import PortavozCore
import StorageKit

extension AppServices {
    /// Launch recovery workflow composed from the durable store, a
    /// multi-root capture-evidence adapter, and the live recording gate.
    var recoverInterruptedMeetings: RecoverInterruptedMeetings {
        RecoverInterruptedMeetings(
            store: store,
            files: AppRecoverInterruptedMeetingsFiles(
                location: RecordingsLocation.shared),
            activity: AppRecoverInterruptedMeetingsActivity(
                recording: recording))
    }
}

@MainActor
private struct AppRecoverInterruptedMeetingsActivity:
    RecoverInterruptedMeetingsActivity {
    let recording: RecordingController

    func recordingPipelineIsActive() async -> Bool {
        switch recording.phase {
        case .preparing, .recording, .processing: true
        case .idle, .done, .failed: false
        }
    }
}

private struct AppRecoverInterruptedMeetingsFiles:
    RecoverInterruptedMeetingsFiles {
    let location: RecordingsLocation

    func recoverPendingAsset(
        _ asset: AudioAsset,
        directory: String,
        at timestamp: Date
    ) async throws -> AudioAsset {
        let location = location
        return try await Task.detached(priority: .utility) {
            try Self.recover(
                asset,
                directory: directory,
                location: location,
                timestamp: timestamp)
        }.value
    }

    private static func recover(
        _ reservation: AudioAsset,
        directory: String,
        location: RecordingsLocation,
        timestamp: Date
    ) throws -> AudioAsset {
        let evidence = try inspect(
            asset: reservation,
            directory: directory,
            location: location)
        var asset = reservation
        asset.updatedAt = timestamp
        switch evidence {
        case .published(let file):
            asset.relativePath = AudioCapturePath.publishedRelativePath(
                directory: directory,
                channel: asset.channel)
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

    private static func inspect(
        asset: AudioAsset,
        directory: String,
        location: RecordingsLocation
    ) throws -> FileEvidence {
        let stagingPath = AudioCapturePath.stagingRelativePath(
            directory: directory,
            channel: asset.channel)
        let publishedPath = AudioCapturePath.publishedRelativePath(
            directory: directory,
            channel: asset.channel)
        let roots = uniqueRoots(location)
        let stagingFiles = existingURLs(relativePath: stagingPath, roots: roots)
        let publishedFiles = existingURLs(relativePath: publishedPath, roots: roots)
        guard stagingFiles.count <= 1,
            publishedFiles.count <= 1,
            stagingFiles.isEmpty || publishedFiles.isEmpty
        else {
            throw RecoverInterruptedMeetingError.ambiguousCapture(asset.channel)
        }

        do {
            if let stagingURL = stagingFiles.first {
                let finalURL = stagingURL.deletingLastPathComponent()
                    .appendingPathComponent(
                        AudioCapturePath.publishedFilename(for: asset.channel))
                return .published(try CaptureFileRecovery.publish(
                    stagingURL: stagingURL,
                    finalURL: finalURL))
            }
            if let publishedURL = publishedFiles.first {
                return .published(try CaptureFileRecovery.inspectPublishedFile(
                    at: publishedURL))
            }
            return .missing
        } catch let error as RecoverInterruptedMeetingError {
            throw error
        } catch {
            throw RecoverInterruptedMeetingError.invalidCapture(asset.channel)
        }
    }

    private static func uniqueRoots(_ location: RecordingsLocation) -> [URL] {
        var paths: Set<String> = []
        return [location.currentRoot(), location.defaultRoot].filter {
            paths.insert($0.standardizedFileURL.path).inserted
        }
    }

    private static func existingURLs(
        relativePath: String,
        roots: [URL]
    ) -> [URL] {
        roots.map { $0.appendingPathComponent(relativePath) }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

private enum FileEvidence: Sendable {
    case published(PublishedCaptureFile)
    case missing
}
