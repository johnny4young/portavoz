import ApplicationKit
import AudioCaptureKit
import Foundation
import OSLog
import PortavozCore
import StorageKit

/// Process-launch adapter around ApplicationKit recovery. It owns only the
/// temp-store UI fixture, OSLog mapping, and broad released invalidation.
@MainActor
enum RecordingRecoveryCoordinator {
    private static let logger = Logger(
        subsystem: "app.portavoz.mac",
        category: "recording-recovery")

    static func runIfNeeded(services: AppServices) async {
        let arguments = ProcessInfo.processInfo.arguments
        guard !arguments.contains(where: { $0.hasPrefix("--bench") }) else { return }

        do {
            try await seedFixtureIfRequested(
                services: services,
                arguments: arguments)
        } catch {
            logger.error("Could not prepare recovery fixture: \(error.localizedDescription)")
        }

        let result = await services.recoverInterruptedMeetings.execute(
            RecoverInterruptedMeetingsRequest())
        log(result.issues)
        if result.libraryInvalidationRequired {
            services.libraryVersion += 1
        }
    }

    private static func log(_ issues: [RecoverInterruptedMeetingsIssue]) {
        for issue in issues {
            switch issue.stage {
            case .expiredLeaseRecovery:
                logger.error(
                    "Could not recover expired processing leases: \(issue.message)")
            case .candidateLoading:
                logger.error(
                    "Could not load meetings for launch recovery: \(issue.message)")
            case .failurePreservation(let meetingID):
                logger.error(
                    "Could not preserve interrupted meeting \(meetingID.rawValue.uuidString): \(issue.message)")
            }
        }
    }

    private static func seedFixtureIfRequested(
        services: AppServices,
        arguments: [String]
    ) async throws {
        guard arguments.contains("-seed-recovery") else { return }
        guard arguments.contains("-use-temp-store") else {
            throw RecoveryFixtureError.fixtureRequiresTemporaryStore
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
                directory: "Audio/recovery-fixture",
                channel: .microphone),
            at: meeting.startedAt)
        try await services.store.beginRecording(meeting, assets: [reservation])

        let directory = RecordingsLocation.shared.currentRoot()
            .appendingPathComponent("Audio/recovery-fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        let stagingURL = directory.appendingPathComponent(
            AudioCapturePath.stagingFilename(for: .microphone))
        try autoreleasepool {
            let writer = try CaptureFileWriter(url: stagingURL, sampleRate: 16_000)
            try writer.append([Float](repeating: 0.25, count: 16_000))
        }
    }
}

private enum RecoveryFixtureError: Error {
    case fixtureRequiresTemporaryStore
}
