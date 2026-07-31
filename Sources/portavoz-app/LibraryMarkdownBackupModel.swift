import ApplicationKit
import Foundation
import Observation

@MainActor
protocol LibraryMarkdownBackupModelClient: Sendable {
    func recoverLibraryMarkdownBackup(
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupRecoveryExecution

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
    private var didRecoverAtLaunch = false
    private var hasPendingLaunchRecovery = false

    init(client: any LibraryMarkdownBackupModelClient) {
        self.client = client
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func recoverAtLaunch() async {
        guard !didRecoverAtLaunch else { return }
        didRecoverAtLaunch = true
        hasPendingLaunchRecovery = true
        phase = .running(.preparing)
        await continueLaunchRecovery()
    }

    func export(to directory: URL) async {
        guard !isRunning, !hasPendingLaunchRecovery else { return }
        pendingDirectory = directory
        resumeRequested = false
        phase = .running(.preparing)
        await continuePendingExport()
    }

    /// A capture-stop signal is remembered even if admission is still being
    /// evaluated, so the pending export cannot miss its only resume wake.
    func maintenanceMayResume() {
        guard pendingDirectory != nil || hasPendingLaunchRecovery else { return }
        resumeRequested = true
        guard !isExecuting else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if self.hasPendingLaunchRecovery {
                await self.continueLaunchRecovery()
            } else {
                await self.continuePendingExport()
            }
        }
    }

    private func continueLaunchRecovery() async {
        guard !isExecuting, hasPendingLaunchRecovery else { return }
        isExecuting = true
        phase = .running(.preparing)
        do {
            let execution = try await client.recoverLibraryMarkdownBackup { [weak self] progress in
                await self?.receive(progress)
            }
            switch execution {
            case .none:
                finishLaunchRecovery()
                phase = .idle
            case .completed(let result):
                finishLaunchRecovery()
                phase = .completed(result)
            case .suspended:
                isExecuting = false
                if resumeRequested {
                    resumeRequested = false
                    await continueLaunchRecovery()
                }
            }
        } catch {
            if error as? LibraryMarkdownBackupLaunchRecoveryError == .terminated {
                finishLaunchRecovery()
            } else {
                isExecuting = false
                resumeRequested = false
            }
            phase = .failed(Self.failure(for: error))
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
            case .operationInProgress: phase = .failed(.unexpected)
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

    private func finishLaunchRecovery() {
        hasPendingLaunchRecovery = false
        isExecuting = false
        resumeRequested = false
    }

    private func receive(_ progress: LibraryMarkdownBackupProgressEvent) {
        guard isRunning else { return }
        phase = .running(progress)
    }

    private static func failure(for error: Error) -> Failure {
        if let error = error as? LibraryMarkdownBackupError {
            switch error {
            case .libraryUnavailable: return .libraryUnavailable
            case .destinationUnavailable: return .destinationUnavailable
            case .operationInProgress: return .unexpected
            }
        }
        if let error = error as? LibraryMarkdownBackupLaunchRecoveryError {
            switch error {
            case .recoveryUnavailable, .sourceUnavailable, .terminated:
                return .libraryUnavailable
            case .ambiguousRecovery, .blocked:
                return .unexpected
            }
        }
        return .unexpected
    }
}
