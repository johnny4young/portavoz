import Foundation
import PortavozCore

public struct RecoverLibraryMarkdownBackupRequest: Sendable {
    public let progress: LibraryMarkdownBackupProgressHandler

    public init(
        progress: @escaping LibraryMarkdownBackupProgressHandler = { _ in }
    ) {
        self.progress = progress
    }
}

public enum LibraryMarkdownBackupRecoveryExecution:
    Equatable,
    Sendable {
    case none
    case completed(LibraryMarkdownBackupResult)
    case suspended
}

public enum LibraryMarkdownBackupLaunchRecoveryError:
    Error,
    Equatable,
    Sendable {
    case ambiguousRecovery
    case blocked
    case recoveryUnavailable
    case sourceUnavailable
    case terminated
}

/// Reconstructs at most one durable whole-library backup after relaunch.
/// Journal cataloging always precedes cleanup, and every cataloged operation
/// protects its matching immutable stage even when strict journal loading later
/// fails. Ambiguous or conflicting evidence is never guessed safe.
public actor RecoverLibraryMarkdownBackup: ApplicationUseCase {
    private static let workload = ResourceWorkloadDescriptor(
        workloadClass: .maintenance,
        kind: .mediaExport,
        operation: .execute)

    private let sourceStore: any LibraryMarkdownBackupRecoverySourceStore
    private let recoveryStore: any LibraryMarkdownBackupRecoveryStore
    private let reconciler: ReconcileBackupPublication
    private let exporter: ExportLibraryMarkdownBackup
    private let maintenanceGate: DurableMaintenanceGate
    private var recoveredDirectory: URL?
    private var isExecuting = false

    public init(
        sourceStore: any LibraryMarkdownBackupRecoverySourceStore,
        recoveryStore: any LibraryMarkdownBackupRecoveryStore,
        reconciler: ReconcileBackupPublication,
        exporter: ExportLibraryMarkdownBackup,
        maintenanceGate: DurableMaintenanceGate = .unrestricted
    ) {
        self.sourceStore = sourceStore
        self.recoveryStore = recoveryStore
        self.reconciler = reconciler
        self.exporter = exporter
        self.maintenanceGate = maintenanceGate
    }

    public func execute(
        _ request: RecoverLibraryMarkdownBackupRequest
    ) async throws -> LibraryMarkdownBackupRecoveryExecution {
        guard !isExecuting else {
            throw LibraryMarkdownBackupError.operationInProgress
        }
        isExecuting = true
        defer { isExecuting = false }

        if let recoveredDirectory {
            return try await resume(
                directory: recoveredDirectory,
                progress: request.progress)
        }

        let operationIDs = try await catalogOperationIDs()
        _ = await sourceStore.cleanupAbandonedLibraryMarkdownBackupSources(
            preserving: operationIDs)
        guard let operationID = operationIDs.first else { return .none }
        guard operationIDs.count == 1 else {
            throw LibraryMarkdownBackupLaunchRecoveryError.ambiguousRecovery
        }
        guard shouldProceed(at: .admission),
              shouldProceed(at: .checkpoint)
        else { return .suspended }

        let state = try await reconcile(operationID: operationID)
        let source = try await adoptSource(for: state)
        if state.phase == .completed {
            return try await finishCompletedRecovery(
                state: state,
                source: source)
        }

        do {
            let directory = try await exporter.restoreRecoveredRun(
                source: source,
                state: state)
            recoveredDirectory = directory
            return try await resume(
                directory: directory,
                progress: request.progress)
        } catch {
            // restoreRecoveredRun releases the adopted source on every setup
            // failure. The journal and immutable stage remain retryable.
            throw error
        }
    }
}

private extension RecoverLibraryMarkdownBackup {
    func shouldProceed(at phase: ResourceGovernorEvaluationPhase) -> Bool {
        maintenanceGate.disposition(
            for: Self.workload,
            phase: phase) == .proceed
    }

    func catalogOperationIDs() async throws -> Set<UUID> {
        do {
            return try await recoveryStore.operationIDs()
        } catch let error as CancellationError {
            throw error
        } catch {
            throw LibraryMarkdownBackupLaunchRecoveryError.recoveryUnavailable
        }
    }

    func reconcile(
        operationID: UUID
    ) async throws -> LibraryMarkdownBackupRecoveryState {
        do {
            switch try await reconciler.execute(
                BackupReconcileRequest(operationID: operationID)
            ) {
            case .unavailable:
                throw LibraryMarkdownBackupLaunchRecoveryError
                    .recoveryUnavailable
            case .blocked:
                throw LibraryMarkdownBackupLaunchRecoveryError.blocked
            case .noPending(let state),
                    .retrySource(let state),
                    .reconciled(let state):
                return state
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as LibraryMarkdownBackupLaunchRecoveryError {
            throw error
        } catch {
            throw LibraryMarkdownBackupLaunchRecoveryError.recoveryUnavailable
        }
    }

    func adoptSource(
        for state: LibraryMarkdownBackupRecoveryState
    ) async throws -> any LibraryMarkdownBackupSourceSession {
        do {
            switch try await sourceStore.adoptLibraryMarkdownBackupSource(
                id: state.operationID,
                cursor: state.sourceCursor
            ) {
            case .ready(let source):
                return source
            case .unavailable:
                throw LibraryMarkdownBackupLaunchRecoveryError.sourceUnavailable
            }
        } catch let error as CancellationError {
            throw error
        } catch let error as LibraryMarkdownBackupLaunchRecoveryError {
            throw error
        } catch {
            throw LibraryMarkdownBackupLaunchRecoveryError.sourceUnavailable
        }
    }

    func finishCompletedRecovery(
        state: LibraryMarkdownBackupRecoveryState,
        source: any LibraryMarkdownBackupSourceSession
    ) async throws -> LibraryMarkdownBackupRecoveryExecution {
        guard LibraryMarkdownBackupRecoveryValidation.isValid(
            state,
            for: source,
            phase: .completed)
        else {
            await source.abandon()
            throw LibraryMarkdownBackupLaunchRecoveryError.recoveryUnavailable
        }
        do {
            try await recoveryStore.remove(operationID: state.operationID)
        } catch let error as CancellationError {
            await source.abandon()
            throw error
        } catch {
            await source.abandon()
            throw LibraryMarkdownBackupLaunchRecoveryError.recoveryUnavailable
        }
        await source.close()
        return .completed(LibraryMarkdownBackupResult(
            totalMeetings: source.totalMeetings,
            exportedFileNames: state.completedPublications.map(\.fileName),
            failures: state.failures.map(\.failure)))
    }

    func resume(
        directory: URL,
        progress: @escaping LibraryMarkdownBackupProgressHandler
    ) async throws -> LibraryMarkdownBackupRecoveryExecution {
        do {
            let execution = try await exporter.execute(
                ExportLibraryMarkdownBackupRequest(
                    directory: directory,
                    progress: progress))
            switch execution {
            case .completed(let result):
                recoveredDirectory = nil
                return .completed(result)
            case .suspended:
                return .suspended
            }
        } catch {
            guard await exporter.hasPendingRun() else {
                recoveredDirectory = nil
                throw LibraryMarkdownBackupLaunchRecoveryError.terminated
            }
            throw error
        }
    }
}
