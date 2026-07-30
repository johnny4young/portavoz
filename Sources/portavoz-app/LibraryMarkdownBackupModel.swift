import ApplicationKit
import Foundation
import Observation

@MainActor
protocol LibraryMarkdownBackupModelClient: Sendable {
    func exportLibraryMarkdownBackup(
        to directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupExecution
}

/// Process-scoped owner for whole-library export state. Closing Settings does
/// not cancel a backup or make a second window start a competing export.
@MainActor
@Observable
final class LibraryMarkdownBackupModel {
    enum Failure: Equatable {
        case libraryUnavailable
        case destinationUnavailable
        case unexpected
    }

    enum Phase: Equatable {
        case idle
        case running(LibraryMarkdownBackupProgressEvent)
        case completed(LibraryMarkdownBackupResult)
        case failed(Failure)
    }

    private(set) var phase: Phase = .idle

    private let client: any LibraryMarkdownBackupModelClient
    private var pendingDirectory: URL?
    private var isExecuting = false
    private var resumeRequested = false

    init(client: any LibraryMarkdownBackupModelClient) {
        self.client = client
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func export(to directory: URL) async {
        guard !isRunning else { return }
        pendingDirectory = directory
        resumeRequested = false
        phase = .running(.preparing)
        await continuePendingExport()
    }

    /// A capture-stop signal is remembered even if admission is still being
    /// evaluated, so the pending export cannot miss its only resume wake.
    func maintenanceMayResume() {
        guard pendingDirectory != nil else { return }
        resumeRequested = true
        guard !isExecuting else { return }
        Task { @MainActor [weak self] in
            await self?.continuePendingExport()
        }
    }

    private func continuePendingExport() async {
        guard !isExecuting, let directory = pendingDirectory else { return }
        isExecuting = true
        do {
            let execution = try await client.exportLibraryMarkdownBackup(
                to: directory
            ) { [weak self] progress in
                await self?.receive(progress)
            }
            switch execution {
            case .completed(let result):
                finish()
                phase = .completed(result)
            case .suspended:
                isExecuting = false
                if resumeRequested {
                    resumeRequested = false
                    await continuePendingExport()
                }
            }
        } catch let error as LibraryMarkdownBackupError {
            finish()
            switch error {
            case .libraryUnavailable: phase = .failed(.libraryUnavailable)
            case .destinationUnavailable: phase = .failed(.destinationUnavailable)
            }
        } catch {
            finish()
            phase = .failed(.unexpected)
        }
    }

    private func finish() {
        pendingDirectory = nil
        isExecuting = false
        resumeRequested = false
    }

    private func receive(_ progress: LibraryMarkdownBackupProgressEvent) {
        guard isRunning else { return }
        phase = .running(progress)
    }
}
