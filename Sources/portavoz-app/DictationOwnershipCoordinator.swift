import AppKit
import DictationOwnership
import Foundation
import Observation

/// Portavoz's side of the cooperative ownership protocol: at most one global capture
/// or delivery per macOS user, across this app, Secreteo and their Dev builds.
/// It is not a security boundary, and it never writes the user's preference.
@MainActor
@Observable
final class DictationOwnershipCoordinator {
    private(set) var state = ParticipantState.off
    @ObservationIgnored var onStateChange: (_ previous: ParticipantState) -> Void = { _ in }
    @ObservationIgnored var onIntentChange: (_ isLive: Bool) -> Void = { _ in }

    @ObservationIgnored private let ownership: DictationOwnership
    @ObservationIgnored private let settle: () async -> Void
    @ObservationIgnored private var observer: OwnershipObserver?
    @ObservationIgnored private var held: SharedLease?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// Step 5 of a handoff arms the triggers just before this app becomes the owner.
    @ObservationIgnored private var armsForHandoff = false

    init(ownership: DictationOwnership, settle: @escaping () async -> Void) {
        self.ownership = ownership
        self.settle = settle
    }

    /// Disposable launches get a scratch folder, so they can never touch the real owner.
    static func live(defaults: UserDefaults, usesTemporaryStore: Bool) -> DictationOwnershipCoordinator {
        let identifier = Bundle.main.bundleIdentifier ?? "app.portavoz.mac.unbundled"
        let peers = usesTemporaryStore ? nil : legacyPeers(excluding: identifier)
        // UserDefaults is thread-safe, and the protocol reads conditions off the main actor.
        nonisolated(unsafe) let preferences = defaults
        let preferenceKey = DictationController.defaultsKey
        let conditions: @Sendable () -> ParticipantConditions = {
            ParticipantConditions(
                preferenceIsOn: preferences.bool(forKey: preferenceKey),
                // The session reports a missing permission or model through its normal path.
                missingForReadiness: nil,
                legacyPeerIsActive: peers?.activePeer() != nil)
        }
        let ownership = usesTemporaryStore
            ? DictationOwnership(
                participant: identifier,
                root: FileManager.default.temporaryDirectory
                    .appendingPathComponent("dictation-ownership-\(UUID().uuidString)", isDirectory: true),
                conditions: conditions)
            : DictationOwnership(participant: identifier, conditions: conditions)
        return DictationOwnershipCoordinator(ownership: ownership) {
            _ = await DictationClipboard.shared.waitForRestoration(on: .general)
        }
    }

    /// Portavoz before the protocol runs dictation with no lock, so another build of it can only refuse.
    private static func legacyPeers(excluding identifier: String) -> NonCooperatingPeers {
        NonCooperatingPeers(
            known: ["app.portavoz.mac", "app.portavoz.mac.dev"]
                .filter { $0 != identifier }
                .map { KnownPeer(identifier: $0, preferenceKey: DictationController.defaultsKey) },
            running: {
                NSWorkspace.shared.runningApplications.compactMap { app in
                    app.bundleIdentifier.map { RunningApp(identifier: $0, bundleURL: app.bundleURL) }
                }
            })
    }

    var admission: DictationAdmission {
        DictationAdmission(
            acquire: { [weak self] kind in self?.acquire(kind) ?? .failure(.dictationOff) },
            isEligible: { [weak self] in self?.state.allowsPrewarm ?? false })
    }

    var armsTriggers: Bool { state.armsTriggers || armsForHandoff }

    func start() {
        _ = ownership.claimAtFirstRun()
        publish(ownership.status())
        guard observer == nil else { return }
        let observer = OwnershipObserver(ownership: ownership) { [weak self] snapshot in
            Task { @MainActor [weak self] in self?.apply(snapshot) }
        }
        self.observer = observer
        Task { await observer.start() }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reevaluate() }
        }
    }

    /// A hint, as is activation or wake: the state is read again and nothing is decided from it.
    func reevaluate() {
        _ = ownership.claimAtFirstRun()
        publish(ownership.status())
        if state == .off {
            Task { [ownership] in _ = await ownership.turnOff() }
        }
        Task { [observer] in await observer?.reevaluate() }
    }

    /// The user's own action in Settings or onboarding.
    func preferenceChanged(
        isOn: Bool, arm: @escaping @MainActor () -> Bool, disarm: @escaping @MainActor () -> Void
    ) async {
        if isOn {
            let triggers = HandoffTriggers(
                arm: { [weak self] in
                    self?.armsForHandoff = true
                    return arm()
                },
                disarm: { [weak self] in
                    self?.armsForHandoff = false
                    disarm()
                })
            _ = await ownership.preferenceTurnedOn(triggers: triggers)
        } else {
            _ = await ownership.turnOff()
        }
        armsForHandoff = false
        publish(ownership.status())
        await observer?.reevaluate()
    }

    private func acquire(_ kind: DictationAdmissionKind) -> Result<DictationLease, DictationAdmissionRefusal> {
        if let held {
            // A new session shares the lease only while the last one waits for the clipboard,
            // and repeats admission on the held lock, so sessions in a row cannot hold off a handoff.
            guard kind == .global, held.lease.kind == .global, held.working == 0 else { return .failure(.busy) }
            let current = ownership.status()
            guard current == .owned else { return .failure(refusal(for: current)) }
            guard held.lease.revalidate() else { return .failure(.busy) }
            held.holders += 1
            held.working += 1
            return .success(lease(sharing: held))
        }
        switch ownership.acquire(kind == .global ? .global : .practice) {
        case .refused(let refusal):
            return .failure(Self.refusal(for: refusal))
        case .admitted(let lease):
            let shared = SharedLease(lease: lease)
            held = shared
            reportHolding(true)
            return .success(self.lease(sharing: shared))
        }
    }

    private func lease(sharing shared: SharedLease) -> DictationLease {
        DictationLease(
            generation: shared.lease.generation,
            revalidate: { shared.lease.revalidate() },
            settle: settle,
            finishWork: { shared.working -= 1 },
            end: { [weak self] in
                shared.holders -= 1
                guard shared.holders == 0 else { return }
                shared.lease.release()
                guard let self, self.held === shared else { return }
                self.held = nil
                self.reportHolding(false)
            })
    }

    private func reportHolding(_ holding: Bool) {
        Task { [observer] in await observer?.setHoldingLease(holding) }
    }

    private func apply(_ snapshot: OwnershipObserver.Snapshot) {
        onIntentChange(snapshot.intent != nil)
        publish(snapshot.state)
    }

    private func publish(_ new: ParticipantState) {
        let previous = state
        guard new != previous else { return }
        state = new
        onStateChange(previous)
    }

    private func refusal(for state: ParticipantState) -> DictationAdmissionRefusal {
        switch state {
        case .off: .dictationOff
        case .transferring: .transferring
        case .available, .preparing: .notOwner
        case .unavailable(let reason): .unavailable(reason)
        case .owned: .busy
        }
    }

    private static func refusal(for refusal: AdmissionRefusal) -> DictationAdmissionRefusal {
        switch refusal {
        case .busy: .busy
        case .transferring: .transferring
        case .notOwner: .notOwner
        case .off: .dictationOff
        case .unavailable(let reason): .unavailable(reason)
        }
    }
}

/// One capture lock shared by this process's sessions. It is unlocked only after the last
/// one ends, because unlocking frees it for everyone sharing the descriptor.
@MainActor
private final class SharedLease {
    let lease: OwnershipLease
    var holders = 1
    /// Sessions still capturing, transcribing or delivering.
    var working = 1

    init(lease: OwnershipLease) {
        self.lease = lease
    }
}

private struct HandoffTriggers: OwnershipTriggers {
    let arm: @MainActor @Sendable () -> Bool
    let disarm: @MainActor @Sendable () -> Void

    func arm() async -> Bool { await arm() }
    func disarm() async { await disarm() }
}
