import AppKit
import CloudKit
import Foundation
import IntegrationsKit
import Observation
import StorageKit

@MainActor
protocol MeetingSyncModelClient: AnyObject {
    func resumeIfConsented() async -> CloudMeetingSyncStatus
    func enable() async -> CloudMeetingSyncStatus
    func accountDidChange() async -> CloudMeetingSyncStatus
    func synchronizeNow() async -> CloudMeetingSyncStatus
    func retryNow() async -> CloudMeetingSyncStatus
    func includeExistingLibrary() async -> CloudMeetingSyncStatus
    func pause() async -> CloudMeetingSyncStatus
    func removeThisDevice() async -> CloudMeetingSyncStatus
    func currentStatus() async -> CloudMeetingSyncStatus
    func observeJournal() async -> AsyncThrowingStream<MeetingSyncJournalStatus, Error>
    func observeAccountChanges() -> AsyncStream<Void>
    func setRemoteNotificationsEnabled(_ enabled: Bool)
}

/// Process-scoped presentation owner for opt-in sync. It converts local
/// journal/account/push signals into serialized manual lifecycle cycles; no
/// SwiftUI view owns a long-lived observer or CloudKit object.
@MainActor
@Observable
final class MeetingSyncModel {
    enum Action {
        case enable
        case synchronize
        case retry
        case includeExistingLibrary
        case pause
        case removeThisDevice
    }

    private(set) var status = CloudMeetingSyncStatus.localOnly
    private(set) var isBusy = false

    private let client: any MeetingSyncModelClient
    private let journalDebounce: Duration
    private var didStart = false
    private var remoteNotificationsEnabled = false
    private var synchronizationRequested = false
    private var accountRefreshRequested = false
    private var queuedActions: [Action] = []
    @ObservationIgnored private var journalTask: Task<Void, Never>?
    @ObservationIgnored private var accountTask: Task<Void, Never>?
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var retryTask: Task<Void, Never>?

    init(
        client: any MeetingSyncModelClient,
        journalDebounce: Duration = .milliseconds(750)
    ) {
        self.client = client
        self.journalDebounce = journalDebounce
    }

    func start() async {
        guard !didStart else { return }
        didStart = true
        await perform { await self.client.resumeIfConsented() }
    }

    func send(_ action: Action) async {
        guard !isBusy else {
            queuedActions.append(action)
            return
        }
        await performAction(action)
    }

    private func performAction(_ action: Action) async {
        switch action {
        case .enable:
            await perform { await self.client.enable() }
        case .synchronize:
            await requestSynchronization()
        case .retry:
            await perform { await self.client.retryNow() }
        case .includeExistingLibrary:
            await perform { await self.client.includeExistingLibrary() }
        case .pause:
            await perform { await self.client.pause() }
        case .removeThisDevice:
            await perform { await self.client.removeThisDevice() }
        }
    }

    /// CloudKit pushes are content-free wakeups. CKSyncEngine fetches the
    /// authenticated records; the payload dictionary is deliberately ignored.
    func remoteChangeReceived() {
        Task { @MainActor [weak self] in
            await self?.requestSynchronization()
        }
    }
}

private extension MeetingSyncModel {
    func perform(
        _ operation: @escaping @MainActor () async -> CloudMeetingSyncStatus
    ) async {
        precondition(!isBusy, "MeetingSyncModel operations must be serialized")
        isBusy = true
        status = await operation()
        isBusy = false
        reconcileObservers()
        await drainRequestedWork()
    }

    func requestSynchronization() async {
        guard status.isEnabled else { return }
        if isBusy {
            synchronizationRequested = true
            return
        }
        await perform { await self.client.synchronizeNow() }
    }

    func requestAccountRefresh() async {
        guard status.isEnabled else { return }
        if isBusy {
            accountRefreshRequested = true
            return
        }
        await perform { await self.client.accountDidChange() }
    }

    func drainRequestedWork() async {
        if !queuedActions.isEmpty {
            let action = queuedActions.removeFirst()
            await performAction(action)
            return
        }
        if accountRefreshRequested {
            accountRefreshRequested = false
            guard status.isEnabled else {
                synchronizationRequested = false
                return
            }
            await perform { await self.client.accountDidChange() }
            return
        }
        if synchronizationRequested, status.isEnabled {
            synchronizationRequested = false
            await perform { await self.client.synchronizeNow() }
        } else {
            synchronizationRequested = false
        }
    }

    func reconcileObservers() {
        guard status.isEnabled else {
            stopObservers()
            return
        }
        if !remoteNotificationsEnabled {
            client.setRemoteNotificationsEnabled(true)
            remoteNotificationsEnabled = true
        }
        startJournalObserverIfNeeded()
        startAccountObserverIfNeeded()
        scheduleRetryWake()
    }

    func startJournalObserverIfNeeded() {
        guard journalTask == nil else { return }
        journalTask = Task { @MainActor [weak self, client] in
            let stream = await client.observeJournal()
            var isInitialSnapshot = true
            do {
                for try await _ in stream {
                    guard !Task.isCancelled, let self else { return }
                    if isInitialSnapshot {
                        isInitialSnapshot = false
                        continue
                    }
                    self.debounceTask?.cancel()
                    self.debounceTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(for: self.journalDebounce)
                        guard !Task.isCancelled else { return }
                        await self.requestSynchronization()
                    }
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.status = await client.currentStatus()
                self.reconcileObservers()
            }
        }
    }

    func startAccountObserverIfNeeded() {
        guard accountTask == nil else { return }
        accountTask = Task { @MainActor [weak self, client] in
            for await _ in client.observeAccountChanges() {
                guard !Task.isCancelled, let self else { return }
                await self.requestAccountRefresh()
            }
        }
    }

    func scheduleRetryWake() {
        retryTask?.cancel()
        retryTask = nil
        guard let retryAt = status.nextRetryAt else { return }
        let delay = max(0, retryAt.timeIntervalSinceNow)
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            await self.requestSynchronization()
        }
    }

    func stopObservers() {
        journalTask?.cancel()
        accountTask?.cancel()
        debounceTask?.cancel()
        retryTask?.cancel()
        journalTask = nil
        accountTask = nil
        debounceTask = nil
        retryTask = nil
        synchronizationRequested = false
        accountRefreshRequested = false
        if remoteNotificationsEnabled {
            client.setRemoteNotificationsEnabled(false)
            remoteNotificationsEnabled = false
        }
    }
}

extension CloudMeetingSyncStatus {
    static var localOnly: CloudMeetingSyncStatus {
        CloudMeetingSyncStatus(
            phase: .localOnly,
            accountStatus: .unknown,
            isEnabled: false,
            initialSeedState: .blocked,
            progress: CloudMeetingSyncProgress(
                pendingLocalChanges: 0,
                queuedTransfers: 0,
                retryingTransfers: 0,
                failedTransfers: 0),
            nextRetryAt: nil,
            failure: nil)
    }

    static func failed(_ failure: CloudMeetingSyncLifecycleFailure) -> CloudMeetingSyncStatus {
        CloudMeetingSyncStatus(
            phase: .failed,
            accountStatus: .unknown,
            isEnabled: false,
            initialSeedState: .blocked,
            progress: CloudMeetingSyncProgress(
                pendingLocalChanges: 0,
                queuedTransfers: 0,
                retryingTransfers: 0,
                failedTransfers: 0),
            nextRetryAt: nil,
            failure: failure)
    }
}

/// App adapter over the platform-neutral lifecycle. A corrupt transport root
/// degrades only sync; Remove this device clears it and reconstructs the
/// lifecycle without touching MeetingStore.
@MainActor
final class LifecycleMeetingSyncClient: MeetingSyncModelClient {
    private let transportRoot: URL
    private let lifecycleFactory: @MainActor () throws -> CloudMeetingSyncLifecycle
    private var lifecycle: CloudMeetingSyncLifecycle?

    init(
        transportRoot: URL,
        lifecycleFactory: @escaping @MainActor () throws -> CloudMeetingSyncLifecycle
    ) {
        self.transportRoot = transportRoot
        self.lifecycleFactory = lifecycleFactory
        lifecycle = try? lifecycleFactory()
    }

    func resumeIfConsented() async -> CloudMeetingSyncStatus {
        guard let lifecycle else { return .failed(.transportStateUnavailable) }
        return await lifecycle.resumeIfConsented()
    }

    func enable() async -> CloudMeetingSyncStatus {
        guard let lifecycle else { return .failed(.transportStateUnavailable) }
        return await lifecycle.enable()
    }

    func accountDidChange() async -> CloudMeetingSyncStatus {
        guard let lifecycle else { return .failed(.transportStateUnavailable) }
        return await lifecycle.accountDidChange()
    }

    func synchronizeNow() async -> CloudMeetingSyncStatus {
        guard let lifecycle else { return .failed(.transportStateUnavailable) }
        return await lifecycle.synchronizeNow()
    }

    func retryNow() async -> CloudMeetingSyncStatus {
        guard let lifecycle else { return .failed(.transportStateUnavailable) }
        return await lifecycle.retryNow()
    }

    func includeExistingLibrary() async -> CloudMeetingSyncStatus {
        guard let lifecycle else { return .failed(.transportStateUnavailable) }
        return await lifecycle.includeExistingLibrary()
    }

    func pause() async -> CloudMeetingSyncStatus {
        guard let lifecycle else { return .failed(.transportStateUnavailable) }
        return await lifecycle.pause()
    }

    func removeThisDevice() async -> CloudMeetingSyncStatus {
        if let lifecycle {
            return await lifecycle.removeThisDevice()
        }
        do {
            try? FileManager.default.removeItem(at: transportRoot)
            lifecycle = try lifecycleFactory()
            return await lifecycle?.currentStatus() ?? .failed(.transportStateUnavailable)
        } catch {
            return .failed(.transportStateUnavailable)
        }
    }

    func currentStatus() async -> CloudMeetingSyncStatus {
        guard let lifecycle else { return .failed(.transportStateUnavailable) }
        return await lifecycle.currentStatus()
    }

    func observeJournal() async -> AsyncThrowingStream<MeetingSyncJournalStatus, Error> {
        guard let lifecycle else {
            return AsyncThrowingStream { $0.finish() }
        }
        return await lifecycle.journalUpdates()
    }

    func observeAccountChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task { @MainActor in
                for await _ in NotificationCenter.default.notifications(
                    named: .CKAccountChanged) {
                    guard !Task.isCancelled else { return }
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func setRemoteNotificationsEnabled(_ enabled: Bool) {
        if enabled {
            NSApplication.shared.registerForRemoteNotifications()
        } else {
            NSApplication.shared.unregisterForRemoteNotifications()
        }
    }
}

/// The XCUITest composition is explicit and deterministic: no signed
/// entitlement probe, CKContainer, iCloud account, APNs registration, or disk
/// transport is involved while Settings behavior remains fully testable.
@MainActor
final class UITestMeetingSyncClient: MeetingSyncModelClient {
    private var status = CloudMeetingSyncStatus.localOnly

    func resumeIfConsented() async -> CloudMeetingSyncStatus { status }

    func enable() async -> CloudMeetingSyncStatus {
        status = readyStatus(seed: .notRequested)
        return status
    }

    func accountDidChange() async -> CloudMeetingSyncStatus { status }
    func synchronizeNow() async -> CloudMeetingSyncStatus { status }
    func retryNow() async -> CloudMeetingSyncStatus { status }

    func includeExistingLibrary() async -> CloudMeetingSyncStatus {
        status = readyStatus(seed: .complete)
        return status
    }

    func pause() async -> CloudMeetingSyncStatus {
        status = .localOnly
        return status
    }

    func removeThisDevice() async -> CloudMeetingSyncStatus {
        status = .localOnly
        return status
    }

    func currentStatus() async -> CloudMeetingSyncStatus { status }

    func observeJournal() async -> AsyncThrowingStream<MeetingSyncJournalStatus, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func observeAccountChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }

    func setRemoteNotificationsEnabled(_ enabled: Bool) {
        _ = enabled
    }

    private func readyStatus(seed: CloudSyncInitialSeedState) -> CloudMeetingSyncStatus {
        CloudMeetingSyncStatus(
            phase: .synchronized,
            accountStatus: .available,
            isEnabled: true,
            initialSeedState: seed,
            progress: CloudMeetingSyncProgress(
                pendingLocalChanges: 0,
                queuedTransfers: 0,
                retryingTransfers: 0,
                failedTransfers: 0),
            nextRetryAt: nil,
            failure: nil)
    }
}
