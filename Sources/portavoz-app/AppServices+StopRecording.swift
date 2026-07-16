import ApplicationKit
import AudioCaptureKit
import Foundation
import PortavozCore

extension AppServices {
    /// Final capture handoff composed from narrow storage, filesystem, and
    /// process-lifecycle adapters. Live session teardown remains in the
    /// recording controller.
    var stopRecording: StopRecording {
        StopRecording(
            audioFiles: AppStopRecordingAudioFiles(root: Self.audioRoot),
            store: store,
            lifecycle: AppStopRecordingLifecycle(services: self))
    }
}

extension StopRecordingCapture {
    init(
        _ summary: RecordingSession.Summary,
        transcriptRequiresRecovery: Bool = false
    ) {
        self.init(
            publishedFiles: summary.publishedFiles.mapValues {
                StopRecordingPublishedFile(
                    container: $0.container,
                    codec: $0.codec,
                    sampleRate: $0.sampleRate,
                    channelCount: $0.channelCount,
                    durationSeconds: $0.durationSeconds,
                    byteCount: $0.byteCount,
                    sha256: $0.sha256,
                    healthStatus: $0.healthStatus,
                    peakDBFS: $0.peakDBFS,
                    rmsDBFS: $0.rmsDBFS)
            },
            transcriptRequiresRecovery: transcriptRequiresRecovery)
    }
}

private struct AppStopRecordingAudioFiles: StopRecordingAudioFiles {
    let root: URL

    func captureFileExists(relativePath: String) async -> Bool {
        let fileURL = root.appendingPathComponent(relativePath)
        return await Task.detached(priority: .utility) {
            FileManager.default.fileExists(atPath: fileURL.path)
        }.value
    }
}

@MainActor
private final class AppStopRecordingLifecycle: StopRecordingLifecycle {
    private weak var services: AppServices?

    init(services: AppServices) {
        self.services = services
    }

    func kickPostCaptureProcessing() async {
        services?.kickPostCaptureProcessing()
    }

    func scheduleRecordingEngineRelease() async {
        services?.scheduleRecordingEnginesRelease()
    }
}
