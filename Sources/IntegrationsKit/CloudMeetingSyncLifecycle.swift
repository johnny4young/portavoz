import Foundation
import StorageKit

public struct CloudMeetingSyncAccountIdentity: Equatable, Sendable {
    public let status: CloudSyncAccountStatus
    public let fingerprint: String?

    public init(status: CloudSyncAccountStatus, fingerprint: String?) {
        self.status = status
        self.fingerprint = fingerprint
    }
}

public enum CloudMeetingSyncPlatformError: Error, Equatable, Sendable {
    case capabilityUnavailable
    case accountCheckFailed
    case accountIdentityUnavailable
    case transportCreationFailed
    case synchronizationFailed
}

/// A manually driven CloudKit session. The production implementation owns
/// CKSyncEngine; tests inject a deterministic driver without an account or
/// network dependency.
public protocol CloudMeetingSyncEngineDriving: Sendable {
    func synchronize() async throws
    func cancel() async
}

/// Platform seam for account discovery and transport construction. Merely
/// creating the lifecycle never calls either method, so a clean local-only
/// launch cannot instantiate CKContainer or touch the network.
public protocol CloudMeetingSyncPlatform: Sendable {
    func accountIdentity() async throws -> CloudMeetingSyncAccountIdentity
    func makeDriver(
        delegate: CloudMeetingSyncEngineDelegate
    ) async throws -> any CloudMeetingSyncEngineDriving
}

/// Owns the account-scoped opt-in and user-action semantics above the durable
/// D95 transport. StorageKit remains the meeting mutation/replay authority;
/// this actor only coordinates readiness, manual cycles, and truthful status.
public actor CloudMeetingSyncLifecycle {
    private let meetingStore: MeetingStore
    private let transportStore: CloudMeetingSyncStateStore
    private let coordinator: CloudMeetingSyncCoordinator
    private let delegate: CloudMeetingSyncEngineDelegate
    private let platform: any CloudMeetingSyncPlatform
    private var driver: (any CloudMeetingSyncEngineDriving)?
    private var lifecycleFailure: CloudMeetingSyncLifecycleFailure?
    private var isSynchronizing = false

    public init(
        meetingStore: MeetingStore,
        transportStore: CloudMeetingSyncStateStore,
        localDeviceID: UUID,
        platform: any CloudMeetingSyncPlatform
    ) {
        self.meetingStore = meetingStore
        self.transportStore = transportStore
        self.platform = platform
        let coordinator = CloudMeetingSyncCoordinator(
            meetingStore: meetingStore,
            transportStore: transportStore,
            localDeviceID: localDeviceID)
        self.coordinator = coordinator
        delegate = CloudMeetingSyncEngineDelegate(
            coordinator: coordinator,
            transportStore: transportStore)
    }

    /// A local-only launch stops here unless a previous account-scoped opt-in
    /// exists. This is the sole automatic process-launch entry point.
    @discardableResult
    public func resumeIfConsented() async -> CloudMeetingSyncStatus {
        let snapshot = await transportStore.currentSnapshot()
        guard snapshot.consentedAccountFingerprint != nil else {
            return await currentStatus()
        }
        return await refreshAccountAndSynchronize(grantConsent: false)
    }

    /// Explicit user opt-in. Existing meetings are deliberately not seeded;
    /// `includeExistingLibrary()` is a separate, equally explicit action.
    @discardableResult
    public func enable() async -> CloudMeetingSyncStatus {
        await refreshAccountAndSynchronize(grantConsent: true)
    }

    /// Re-checks an already-consented account after CKAccountChanged. A real
    /// account switch clears consent in D95 and cannot silently opt in again.
    @discardableResult
    public func accountDidChange() async -> CloudMeetingSyncStatus {
        let snapshot = await transportStore.currentSnapshot()
        guard snapshot.consentedAccountFingerprint != nil else {
            return await currentStatus()
        }
        return await refreshAccountAndSynchronize(grantConsent: false)
    }

    @discardableResult
    public func synchronizeNow() async -> CloudMeetingSyncStatus {
        guard (await transportStore.currentSnapshot()).isTransportReady else {
            return await currentStatus()
        }
        return await performSync()
    }

    /// Expedites deterministic backoff and explicitly re-admits blocked
    /// record attempts before one user-requested cycle.
    @discardableResult
    public func retryNow(at date: Date = Date()) async -> CloudMeetingSyncStatus {
        do {
            _ = try await transportStore.retryPendingAttempts(at: date)
        } catch {
            lifecycleFailure = .transportStateUnavailable
            return await currentStatus()
        }
        return await synchronizeNow()
    }

    @discardableResult
    public func includeExistingLibrary(at date: Date = Date()) async -> CloudMeetingSyncStatus {
        do {
            _ = try await coordinator.requestInitialSeed(at: date)
        } catch {
            lifecycleFailure = .transportStateUnavailable
            return await currentStatus()
        }
        return await performSync()
    }

    /// Stops this Mac without deleting local meetings, remote records, or the
    /// protected queue. Re-enabling the same account resumes exact attempts.
    @discardableResult
    public func pause() async -> CloudMeetingSyncStatus {
        await driver?.cancel()
        driver = nil
        do {
            try await transportStore.revokeConsent()
            lifecycleFailure = nil
        } catch {
            lifecycleFailure = .transportStateUnavailable
        }
        return await currentStatus()
    }

    /// Forgets only this device's transport metadata and protected queue.
    /// Meeting content on this Mac and encrypted records already in iCloud are
    /// intentionally untouched; a later full-library seed remains explicit.
    @discardableResult
    public func removeThisDevice() async -> CloudMeetingSyncStatus {
        await driver?.cancel()
        driver = nil
        do {
            try await transportStore.removeThisDeviceState()
            lifecycleFailure = nil
        } catch {
            lifecycleFailure = .transportStateUnavailable
        }
        return await currentStatus()
    }

    public func currentStatus() async -> CloudMeetingSyncStatus {
        let snapshot = await transportStore.currentSnapshot()
        let journal: MeetingSyncJournalStatus
        let journalFailure: CloudMeetingSyncLifecycleFailure?
        do {
            journal = try await meetingStore.meetingSyncJournalStatus()
            journalFailure = nil
        } catch {
            journal = MeetingSyncJournalStatus(pendingCount: 0, newestChangeAt: nil)
            journalFailure = .journalUnavailable
        }
        let delegateFailure = await delegate.lastFailure()
        let retrying = snapshot.attempts.filter { $0.phase == .retryWaiting }
        let blocked = snapshot.attempts.filter { $0.phase == .blocked }
        let progress = CloudMeetingSyncProgress(
            pendingLocalChanges: journal.pendingCount,
            queuedTransfers: snapshot.attempts.count,
            retryingTransfers: retrying.count,
            failedTransfers: blocked.count)
        let failure = journalFailure ?? lifecycleFailure
        let enabled = snapshot.consentedAccountFingerprint != nil
        let phase = Self.phase(
            snapshot: snapshot,
            enabled: enabled,
            progress: progress,
            isSynchronizing: isSynchronizing,
            delegateFailed: delegateFailure != nil,
            lifecycleFailure: failure)
        return CloudMeetingSyncStatus(
            phase: phase,
            accountStatus: snapshot.accountStatus,
            isEnabled: enabled,
            initialSeedState: snapshot.initialSeedState,
            progress: progress,
            nextRetryAt: retrying.compactMap(\.nextRetryAt).min(),
            failure: failure ?? (delegateFailure == nil ? nil : .synchronizationFailed))
    }

    public func journalUpdates() -> AsyncThrowingStream<MeetingSyncJournalStatus, Error> {
        meetingStore.observeMeetingSyncJournalStatus()
    }
}

private extension CloudMeetingSyncLifecycle {
    func refreshAccountAndSynchronize(grantConsent: Bool) async -> CloudMeetingSyncStatus {
        let identity: CloudMeetingSyncAccountIdentity
        do {
            identity = try await platform.accountIdentity()
        } catch {
            lifecycleFailure = Self.failure(for: error, fallback: .accountCheckFailed)
            driver = nil
            return await currentStatus()
        }

        if identity.status == .available, identity.fingerprint == nil {
            lifecycleFailure = .accountIdentityUnavailable
            driver = nil
            return await currentStatus()
        }

        do {
            try await transportStore.updateAccount(
                status: identity.status,
                fingerprint: identity.fingerprint)
        } catch {
            lifecycleFailure = .transportStateUnavailable
            driver = nil
            return await currentStatus()
        }

        guard identity.status == .available, let fingerprint = identity.fingerprint else {
            await driver?.cancel()
            driver = nil
            lifecycleFailure = nil
            return await currentStatus()
        }

        let snapshot = await transportStore.currentSnapshot()
        if grantConsent {
            do {
                try await transportStore.grantConsent(
                    forAccountFingerprint: fingerprint,
                    at: Date())
            } catch {
                lifecycleFailure = .transportStateUnavailable
                return await currentStatus()
            }
        } else if snapshot.consentedAccountFingerprint != fingerprint {
            await driver?.cancel()
            driver = nil
            lifecycleFailure = nil
            return await currentStatus()
        }
        return await performSync()
    }

    func performSync() async -> CloudMeetingSyncStatus {
        let snapshot = await transportStore.currentSnapshot()
        guard snapshot.isTransportReady else { return await currentStatus() }
        do {
            if driver == nil {
                driver = try await platform.makeDriver(delegate: delegate)
            }
        } catch {
            lifecycleFailure = Self.failure(for: error, fallback: .transportCreationFailed)
            return await currentStatus()
        }
        guard let driver else {
            lifecycleFailure = .transportCreationFailed
            return await currentStatus()
        }

        isSynchronizing = true
        lifecycleFailure = nil
        await delegate.clearLastFailure()
        do {
            try await driver.synchronize()
            isSynchronizing = false
            if await delegate.lastFailure() == nil {
                lifecycleFailure = nil
            }
        } catch {
            isSynchronizing = false
            lifecycleFailure = Self.failure(for: error, fallback: .synchronizationFailed)
        }
        return await currentStatus()
    }

    static func phase(
        snapshot: CloudMeetingSyncSnapshot,
        enabled: Bool,
        progress: CloudMeetingSyncProgress,
        isSynchronizing: Bool,
        delegateFailed: Bool,
        lifecycleFailure: CloudMeetingSyncLifecycleFailure?
    ) -> CloudMeetingSyncPhase {
        guard enabled else { return lifecycleFailure == nil ? .localOnly : .failed }
        guard snapshot.accountStatus == .available,
              snapshot.currentAccountFingerprint == snapshot.consentedAccountFingerprint
        else { return .paused }
        if lifecycleFailure != nil || delegateFailed || progress.failedTransfers > 0 {
            return .failed
        }
        if progress.retryingTransfers > 0 { return .retrying }
        if isSynchronizing
            || progress.pendingLocalChanges > 0
            || progress.queuedTransfers > 0
            || snapshot.initialSeedState == .requested {
            return .pending
        }
        return .synchronized
    }

    static func failure(
        for error: Error,
        fallback: CloudMeetingSyncLifecycleFailure
    ) -> CloudMeetingSyncLifecycleFailure {
        guard let platformError = error as? CloudMeetingSyncPlatformError else {
            return fallback
        }
        return switch platformError {
        case .capabilityUnavailable: .capabilityUnavailable
        case .accountCheckFailed: .accountCheckFailed
        case .accountIdentityUnavailable: .accountIdentityUnavailable
        case .transportCreationFailed: .transportCreationFailed
        case .synchronizationFailed: .synchronizationFailed
        }
    }
}
