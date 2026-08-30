import ApplicationKit
import Foundation
import PortavozCore
import StorageKit

protocol StandingPreMeetingBriefEventSource:
    UpcomingEventResolving, Sendable {
    func upcomingStandingBriefEvents() async -> [UpcomingEvent]
    func standingBriefEventChanges() async -> AsyncStream<Void>
}

/// One signal-driven process owner for the bounded standing-rule action. It
/// serializes relaunch recovery before new events, schedules only the next
/// lead-window boundary, and never polls the calendar or SQLite.
actor StandingPreMeetingBriefSupervisor {
    private typealias ReconciliationContinuation =
        CheckedContinuation<Void, Error>

    private let store: MeetingStore
    private let preparer: any StandingPreMeetingBriefPreparing
    private let events: any StandingPreMeetingBriefEventSource
    private let captureState: AppResourceCaptureState
    private let calendar: Calendar
    private let now: @Sendable () -> Date

    private var observationTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var workerGeneration = 0
    private var wakeTask: Task<Void, Never>?
    private var needsReconciliation = false
    private var explicitRetryProposalIDs = Set<UUID>()
    private var reconciliationWaiters: [
        UUID: ReconciliationContinuation
    ] = [:]

    init(
        store: MeetingStore,
        preparer: any StandingPreMeetingBriefPreparing,
        events: any StandingPreMeetingBriefEventSource,
        captureState: AppResourceCaptureState,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.preparer = preparer
        self.events = events
        self.captureState = captureState
        self.calendar = calendar
        self.now = now
    }

    deinit {
        observationTask?.cancel()
        worker?.cancel()
        wakeTask?.cancel()
    }

    func start() async {
        guard observationTask == nil else { return }
        let changes = await events.standingBriefEventChanges()
        observationTask = Task { [weak self] in
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await self?.kick()
            }
        }
        kick()
    }

    func kick() {
        needsReconciliation = true
        startWorkerIfNeeded()
    }

    /// Lets an explicit Settings action wait for the same serialized owner
    /// that background signals use. It never starts a second executor, polls,
    /// or bypasses capture priority.
    func reconcileNow() async throws {
        kick()
        try await waitForReconciliation()
    }

    /// Retries only the failed owner selected in Settings. The request joins
    /// the same serialized worker as background reconciliation, but it neither
    /// resumes unrelated owners nor discovers new calendar work.
    func retryNow(_ proposalID: UUID) async throws {
        explicitRetryProposalIDs.insert(proposalID)
        startWorkerIfNeeded()
        try await waitForReconciliation()
    }

    private func waitForReconciliation() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: ReconciliationContinuation) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    reconciliationWaiters[waiterID] = continuation
                }
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancelReconciliationWaiter(waiterID) }
        }
    }

    private func cancelReconciliationWaiter(_ waiterID: UUID) {
        reconciliationWaiters.removeValue(forKey: waiterID)?.resume(
            throwing: CancellationError())
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    func suspendForCapture() {
        needsReconciliation = true
        worker?.cancel()
        cancelScheduledWake()
    }

    func stop() {
        observationTask?.cancel()
        observationTask = nil
        workerGeneration += 1
        worker?.cancel()
        worker = nil
        cancelScheduledWake()
        needsReconciliation = false
        explicitRetryProposalIDs.removeAll(keepingCapacity: true)
        failReconciliationWaiters(CancellationError())
    }

    private func drain(generation: Int) async {
        var reconciliationError: (any Error)?
        while hasPendingWork, !Task.isCancelled {
            guard captureState.current == .inactive else { break }
            let scope: ReconciliationScope
            if !explicitRetryProposalIDs.isEmpty {
                let proposalIDs = explicitRetryProposalIDs
                explicitRetryProposalIDs.removeAll(keepingCapacity: true)
                scope = .retry(proposalIDs)
            } else {
                needsReconciliation = false
                scope = .all
            }
            do {
                try await reconcile(scope)
            } catch is CancellationError {
                restorePendingWork(for: scope)
                if !Task.isCancelled {
                    reconciliationError = CancellationError()
                }
                break
            } catch {
                restorePendingWork(for: scope)
                reconciliationError = error
                break
            }
        }
        guard generation == workerGeneration else { return }
        worker = nil
        if let reconciliationError {
            failReconciliationWaiters(reconciliationError)
            return
        }
        if hasPendingWork, captureState.current == .inactive {
            startWorkerIfNeeded()
            return
        }
        finishReconciliationWaiters()
    }

    private var hasPendingWork: Bool {
        needsReconciliation || !explicitRetryProposalIDs.isEmpty
    }

    private func finishReconciliationWaiters() {
        let waiters = Array(reconciliationWaiters.values)
        reconciliationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume(returning: ()) }
    }

    private func failReconciliationWaiters(_ error: any Error) {
        let waiters = Array(reconciliationWaiters.values)
        reconciliationWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume(throwing: error) }
    }

    private func restorePendingWork(for scope: ReconciliationScope) {
        switch scope {
        case .all:
            needsReconciliation = true
        case .retry(let proposalIDs):
            explicitRetryProposalIDs.formUnion(proposalIDs)
        }
    }

    private func reconcile(_ scope: ReconciliationScope) async throws {
        let snapshot = try await LoadStandingSkillRules(store: store).execute(())
        guard !snapshot.isPaused else {
            cancelScheduledWake()
            return
        }
        let activeRules = Dictionary(uniqueKeysWithValues: snapshot.rules
            .filter(\.isEffectivelyEnabled)
            .map { ($0.rule.id, $0.rule) })
        let pending = try await store.pendingStandingSkillExecutions(
            limit: StandingSkillExecutionPolicy.maximumPendingExecutionCount)
        let executor = makeExecutor()
        let selectedPending = switch scope {
        case .all:
            pending
        case .retry(let proposalIDs):
            pending.filter { proposalIDs.contains($0.record.proposalID) }
        }
        try await resumePending(
            selectedPending,
            activeRules: activeRules,
            executor: executor,
            scope: scope)

        guard scope == .all else { return }

        guard captureState.current == .inactive else {
            needsReconciliation = true
            return
        }
        try await prepareUpcoming(
            activeRules: activeRules,
            executor: executor)
    }

    private func resumePending(
        _ pending: [PendingStandingSkillExecution],
        activeRules: [StandingSkillRuleID: StandingSkillRule],
        executor: ExecuteStandingPreMeetingBrief,
        scope: ReconciliationScope
    ) async throws {
        for (index, owner) in pending.enumerated() {
            try Task.checkCancellation()
            guard captureState.current == .inactive else {
                deferReconciliation(
                    scope,
                    remaining: pending[index...])
                return
            }
            guard owner.record.state != .executing,
                  owner.record.attempt
                    < StandingSkillExecutionPolicy.maximumAutomaticAttempts,
                  activeRules[owner.ruleID] != nil
            else {
                try await cancelConfirmedIfRevoked(owner)
                continue
            }
            guard let event = try await events.upcomingEvent(
                matching: owner.occurrence.eventID),
                  owner.occurrence.matches(
                    eventID: event.id,
                    eventStartAt: event.startDate),
                  ExecuteStandingPreMeetingBrief.isEligible(event, at: now())
            else {
                try await cancelConfirmedIfRevoked(owner)
                continue
            }
            do {
                _ = try await executor.resume(owner, event: event)
            } catch let error as StandingPreMeetingBriefError
                where error == .eventChanged {
                continue
            }
        }
    }

    private func deferReconciliation(
        _ scope: ReconciliationScope,
        remaining: ArraySlice<PendingStandingSkillExecution>
    ) {
        switch scope {
        case .all:
            needsReconciliation = true
        case .retry:
            explicitRetryProposalIDs.formUnion(
                remaining.map(\.record.proposalID))
        }
    }

    private func prepareUpcoming(
        activeRules: [StandingSkillRuleID: StandingSkillRule],
        executor: ExecuteStandingPreMeetingBrief
    ) async throws {
        guard !activeRules.isEmpty else {
            cancelScheduledWake()
            return
        }
        let upcoming = await events.upcomingStandingBriefEvents()
            .filter(\.hasValidIdentity)
            .sorted {
                $0.startDate == $1.startDate
                    ? $0.id < $1.id
                    : $0.startDate < $1.startDate
            }
        scheduleNextStandingWake(for: upcoming)
        var seenEventIDs = Set<String>()
        for rule in activeRules.values.sorted(by: {
            $0.createdAt == $1.createdAt
                ? $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
                : $0.createdAt < $1.createdAt
        }) {
            for event in upcoming where seenEventIDs.insert(event.id).inserted {
                try Task.checkCancellation()
                guard captureState.current == .inactive else {
                    needsReconciliation = true
                    return
                }
                guard ExecuteStandingPreMeetingBrief.isEligible(
                    event,
                    at: now())
                else { continue }
                let outcome: StandingPreMeetingBriefOutcome
                do {
                    outcome = try await executor.execute((rule, event))
                } catch let error as StandingPreMeetingBriefError
                    where error == .eventChanged {
                    continue
                }
                if outcome == .deferred(.dailyBudgetReached) { return }
            }
        }
    }

    private func makeExecutor() -> ExecuteStandingPreMeetingBrief {
        ExecuteStandingPreMeetingBrief(
            store: store,
            preparer: preparer,
            events: events,
            calendar: calendar,
            cancelsClaimOnCancellation: false,
            now: now)
    }

    private func cancelConfirmedIfRevoked(
        _ owner: PendingStandingSkillExecution
    ) async throws {
        guard owner.record.state == .confirmed else { return }
        _ = try await store.cancelSkillExecution(
            proposalID: owner.record.proposalID,
            at: now())
    }

    private func cancelScheduledWake() {
        wakeTask?.cancel()
        wakeTask = nil
    }

    private func scheduleNextStandingWake(
        for events: [UpcomingEvent]
    ) {
        let timestamp = now()
        let next = Self.nextWakeDate(
            for: events,
            at: timestamp,
            calendar: calendar)
        wakeTask?.cancel()
        guard let next else {
            wakeTask = nil
            return
        }
        let delay = max(0, next.timeIntervalSince(timestamp))
        wakeTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
                await self?.kick()
            } catch is CancellationError {
                return
            } catch {
                return
            }
        }
    }

    private enum ReconciliationScope: Equatable {
        case all
        case retry(Set<UUID>)
    }

    static func nextWakeDate(
        for events: [UpcomingEvent],
        at timestamp: Date,
        calendar: Calendar
    ) -> Date? {
        let nextLeadWindow = events.lazy
            .map {
                $0.startDate.addingTimeInterval(
                    -ExecuteStandingPreMeetingBrief.maximumPreparationLeadTime)
            }
            .filter { $0 > timestamp }
            .min()
        let dayStart = calendar.startOfDay(for: timestamp)
        let horizonRefresh = calendar.date(
            byAdding: .day,
            value: 1,
            to: dayStart)
        return [nextLeadWindow, horizonRefresh].compactMap { $0 }.min()
    }
}
