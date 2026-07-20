import ApplicationKit
import Foundation
import Observation

@MainActor
protocol LibraryMarkdownBackupModelClient: Sendable {
    func exportLibraryMarkdownBackup(
        to directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupResult
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

    init(client: any LibraryMarkdownBackupModelClient) {
        self.client = client
    }

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func export(to directory: URL) async {
        guard !isRunning else { return }
        phase = .running(.preparing)
        do {
            let result = try await client.exportLibraryMarkdownBackup(
                to: directory
            ) { [weak self] progress in
                await self?.receive(progress)
            }
            phase = .completed(result)
        } catch let error as LibraryMarkdownBackupError {
            switch error {
            case .libraryUnavailable: phase = .failed(.libraryUnavailable)
            case .destinationUnavailable: phase = .failed(.destinationUnavailable)
            }
        } catch {
            phase = .failed(.unexpected)
        }
    }

    private func receive(_ progress: LibraryMarkdownBackupProgressEvent) {
        guard isRunning else { return }
        phase = .running(progress)
    }
}
