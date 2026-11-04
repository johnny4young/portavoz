import AppKit
import DictationOwnership
import Foundation
import PortavozCore
import Synchronization
import Testing

@testable import portavoz_app
@testable import PortavozTestSupport

/// The protocol's app acceptance rows, against the real locks in a scratch folder.
@Suite(.serialized, .exclusiveArgumentDomain, .timeLimit(.minutes(1)))
@MainActor
struct DictationOwnershipCoordinatorTests {
    private static let portavoz = "app.portavoz.mac"
    private static let other = "com.example.other"

    @MainActor
    private final class Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-ownership-\(UUID().uuidString)", isDirectory: true)
        var settle: () async -> Void = {}
        var lastOwnership: DictationOwnership?

        func participant(_ identifier: String) -> DictationOwnership {
            DictationOwnership(
                participant: identifier, root: root,
                conditions: {
                    ParticipantConditions(preferenceIsOn: true, missingForReadiness: nil, legacyPeerIsActive: false)
                },
                notificationName: "app.portavoz.ownership-tests.\(root.lastPathComponent)")
        }

        /// Portavoz as the owner.
        func coordinator() -> DictationOwnershipCoordinator {
            let ownership = participant(DictationOwnershipCoordinatorTests.portavoz)
            lastOwnership = ownership
            let coordinator = DictationOwnershipCoordinator(ownership: ownership) { [self] in await settle() }
            coordinator.start()
            return coordinator
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private final class Preference: Sendable {
        let isOn = Mutex(false)
    }

    private struct Triggers: OwnershipTriggers {
        func arm() async -> Bool { true }
        func disarm() async {}
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        _ = await TestPolling.until(condition)
        try #require(condition())
    }

    private func acquire(_ coordinator: DictationOwnershipCoordinator) throws -> DictationLease {
        try coordinator.admission.acquire(.global).get()
    }

    /// Leaves `lease` waiting on the clipboard, which is what a new session may share.
    private func waitOnClipboard(
        _ lease: DictationLease, scratch: Scratch
    ) async throws -> (gate: PreparationGate, finished: Task<Void, Never>) {
        let gate = PreparationGate()
        scratch.settle = { await gate.wait() }
        let finished = Task { await lease.releaseAfterDelivery() }
        try await eventually { gate.started }
        return (gate, finished)
    }

    @Test(arguments: [
        ("app.portavoz.mac", false, true),
        ("app.portavoz.mac.dev", false, true),
        ("app.portavoz.mac", true, false),
        ("com.apple.dt.xctest.tool", false, false),
        ("app.portavoz.mac.uitest-host", false, false),
        ("app.portavoz.mac.unbundled", false, false),
    ])
    func onlyAShippedBuildWithARealLibraryTouchesTheRealOwner(_ example: (String, Bool, Bool)) {
        #expect(DictationOwnershipCoordinator.usesRealOwner(
            identifier: example.0, usesTemporaryStore: example.1) == example.2)
    }

    @Test
    func anActivationBeforeLaunchFinishesPublishesNothing() {
        let scratch = Scratch()
        let ownership = scratch.participant(Self.portavoz)
        let coordinator = DictationOwnershipCoordinator(ownership: ownership) {}
        var changes = 0
        coordinator.onStateChange = { _ in changes += 1 }

        coordinator.reevaluate()

        #expect(coordinator.state == .off)
        #expect(changes == 0)
        coordinator.start()
        #expect(coordinator.state == .owned)
        #expect(changes == 1)
    }

    @Test
    func aClaimThatMetABusyLockIsRetriedOnTheNextHint() throws {
        let scratch = Scratch()
        guard case .admitted(let other) = scratch.participant(Self.other).acquire(.practice) else {
            Issue.record("The other app could not take the lock")
            return
        }
        let coordinator = scratch.coordinator()
        #expect(coordinator.state == .available)

        other.release()
        coordinator.reevaluate()

        #expect(coordinator.state == .owned)
    }

    @Test
    func aLockFileReplacedDuringTheRestoreRefusesTheJoin() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let first = try acquire(coordinator)
        let (gate, finished) = try await waitOnClipboard(first, scratch: scratch)
        let lock = scratch.root.appendingPathComponent("capture.lock")
        try FileManager.default.removeItem(at: lock)
        try Data().write(to: lock)

        #expect(throws: DictationAdmissionRefusal.unavailable(.ioError)) { try acquire(coordinator) }

        gate.release()
        await finished.value
    }

    @Test
    func watchingContinuesUntilTheLastRelease() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let first = try acquire(coordinator)
        let (gate, finished) = try await waitOnClipboard(first, scratch: scratch)
        let second = try acquire(coordinator)
        gate.release()
        await finished.value

        #expect(coordinator.holdsLease)

        second.release()

        #expect(!coordinator.holdsLease)
    }

    @Test
    func aFirstRunWithThePreferenceOnBecomesTheOwner() {
        let scratch = Scratch()

        let coordinator = scratch.coordinator()

        #expect(coordinator.state == .owned)
        #expect(coordinator.armsTriggers)
        #expect(coordinator.admission.isEligible())
    }

    @Test
    func anotherAppIsRefusedWhileThisOneHoldsItsLease() throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let lease = try acquire(coordinator)
        defer { lease.release() }

        guard case .refused(.busy) = scratch.participant(Self.other).acquire(.practice) else {
            Issue.record("The other app got in")
            return
        }
    }

    @Test
    func aNonOwnerIsRefusedAndArmsNothing() async throws {
        let scratch = Scratch()
        let other = scratch.participant(Self.other)
        #expect(await other.takeOwnership(userConfirmed: true, triggers: Triggers()) == .completed(generation: 1))

        let coordinator = scratch.coordinator()

        #expect(coordinator.state == .available)
        #expect(!coordinator.armsTriggers)
        #expect(!coordinator.admission.isEligible())
        #expect(throws: DictationAdmissionRefusal.notOwner) { try coordinator.admission.acquire(.global).get() }
        #expect(throws: Never.self) {
            try coordinator.admission.acquire(.practice).get().release()
        }
    }

    @Test
    func aNewSessionDuringCaptureOrDeliveryIsRefusedBusy() throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let working = try acquire(coordinator)
        defer { working.release() }

        #expect(throws: DictationAdmissionRefusal.busy) { try acquire(coordinator) }
    }

    @Test
    func aNewSessionDuringTheRestoreSharesTheLease() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let first = try acquire(coordinator)
        let (gate, finished) = try await waitOnClipboard(first, scratch: scratch)

        let second = try acquire(coordinator)

        #expect(second.revalidate())
        #expect(throws: DictationAdmissionRefusal.busy) { try acquire(coordinator) }
        second.release()
        gate.release()
        await finished.value
    }

    @Test
    func anEarlyReleaseKeepsTheLockUntilTheLastSessionEnds() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let other = scratch.participant(Self.other)
        let first = try acquire(coordinator)
        let (gate, finished) = try await waitOnClipboard(first, scratch: scratch)
        let second = try acquire(coordinator)

        gate.release()
        await finished.value

        guard case .refused(.busy) = other.acquire(.practice) else {
            Issue.record("The lock was freed under the second session")
            return
        }

        second.release()

        guard case .admitted(let lease) = other.acquire(.practice) else {
            Issue.record("The lock was not free after the last session")
            return
        }
        lease.release()
    }

    @Test
    func practiceIsRefusedDuringAGlobalRestore() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let first = try acquire(coordinator)
        let (gate, finished) = try await waitOnClipboard(first, scratch: scratch)

        #expect(throws: DictationAdmissionRefusal.busy) { try coordinator.admission.acquire(.practice).get() }

        gate.release()
        await finished.value
    }

    @Test
    func aRefusedJoinLeavesTheLockWithTheEarlierSession() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let first = try acquire(coordinator)
        let (gate, finished) = try await waitOnClipboard(first, scratch: scratch)
        let other = scratch.participant(Self.other)
        let handoff = Task { await other.takeOwnership(userConfirmed: true, triggers: Triggers()) }
        try await eventually { ownershipStatus(scratch) == .transferring }

        #expect(throws: DictationAdmissionRefusal.transferring) { try acquire(coordinator) }

        guard case .refused(.busy) = other.acquire(.practice) else {
            Issue.record("A refused join gave up the earlier session's lock")
            return
        }
        gate.release()
        await finished.value
        _ = await handoff.value
    }

    @Test
    func aPracticeLeaseIsNeverShared() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let practice = try coordinator.admission.acquire(.practice).get()
        let (gate, finished) = try await waitOnClipboard(practice, scratch: scratch)

        #expect(throws: DictationAdmissionRefusal.busy) { try acquire(coordinator) }
        #expect(throws: DictationAdmissionRefusal.busy) { try coordinator.admission.acquire(.practice).get() }

        gate.release()
        await finished.value
    }

    @Test
    func aLiveIntentRefusesANewSessionAndTheHandoffCompletesAfterTheRestore() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let first = try acquire(coordinator)
        let (gate, finished) = try await waitOnClipboard(first, scratch: scratch)
        let other = scratch.participant(Self.other)
        let handoff = Task { await other.takeOwnership(userConfirmed: true, triggers: Triggers()) }
        try await eventually { ownershipStatus(scratch) == .transferring }

        #expect(throws: DictationAdmissionRefusal.transferring) { try acquire(coordinator) }

        gate.release()
        await finished.value
        #expect(await handoff.value == .completed(generation: 2))
        #expect(!first.revalidate())
    }

    private func ownershipStatus(_ scratch: Scratch) -> ParticipantState? {
        scratch.lastOwnership?.status()
    }

    @Test
    func aHandoffThereAndBackChangesTheGeneration() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let read = try acquire(coordinator)
        read.release()
        let other = scratch.participant(Self.other)
        #expect(await other.takeOwnership(userConfirmed: true, triggers: Triggers()) == .completed(generation: 2))
        let portavoz = try #require(scratch.lastOwnership)
        #expect(await portavoz.takeOwnership(userConfirmed: true, triggers: Triggers()) == .completed(generation: 3))
        coordinator.reevaluate()

        let replace = try acquire(coordinator)
        defer { replace.release() }

        #expect(replace.generation != read.generation)
        #expect(replace.revalidate())
    }

    @Test
    func turningThePreferenceOnTakesOwnershipFromNobody() async {
        let scratch = Scratch()
        let preference = Preference()
        let ownership = DictationOwnership(participant: "app.portavoz.mac.dev", root: scratch.root, conditions: {
            ParticipantConditions(
                preferenceIsOn: preference.isOn.withLock { $0 }, missingForReadiness: nil, legacyPeerIsActive: false)
        })
        let coordinator = DictationOwnershipCoordinator(ownership: ownership) {}
        coordinator.start()
        #expect(coordinator.state == .off)
        preference.isOn.withLock { $0 = true }
        var armed = 0

        await coordinator.preferenceChanged(isOn: true, arm: { armed += 1; return true }, disarm: {})

        #expect(coordinator.state == .owned)
        #expect(armed > 0)

        preference.isOn.withLock { $0 = false }
        await coordinator.preferenceChanged(isOn: false, arm: { true }, disarm: {})

        #expect(coordinator.state == .off)
        #expect(!coordinator.armsTriggers)
    }

    // MARK: Sessions

    @Test
    func anIntentCancelsASessionStillPreparing() async throws {
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        var dependencies = harness.dependencies
        dependencies.authorizeMicrophone = { try? await Task.sleep(for: .seconds(3_600)); return false }
        harness.controller.toggle(using: dependencies)
        #expect(harness.controller.phase == .preparing)

        harness.controller.ownershipIntentSeen()

        #expect(harness.controller.phase == .idle)
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func anIntentCancelsAPracticeSessionAtOnce() async throws {
        let harness = DictationControllerHarness(text: "Hola")
        let practice = DictationPracticeField()
        practice.show(UUID(), isKey: true)
        harness.controller.toggle(using: practice.route(harness.dependencies, appIsActive: true))
        _ = await TestPolling.until { harness.controller.partialText == "Hola" }

        harness.controller.ownershipIntentSeen()

        #expect(harness.controller.phase == .idle)
        #expect(practice.text.isEmpty)
    }

    @Test
    func aListeningSessionKeepsItsWordsWhenTheGraceEnds() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = harness.dependencies
        dependencies.handoffGrace = .milliseconds(50)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)

        harness.controller.ownershipIntentSeen()

        #expect(harness.controller.phase == .listening, "It keeps listening during the grace")
        try await eventually { harness.controller.phase == .recovery(.ownershipChanged) }
        #expect(harness.controller.recoveryText == harness.text)
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func aSessionFinishedInsideTheGraceDeliversNormally() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = harness.dependencies
        dependencies.handoffGrace = .seconds(3_600)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.ownershipIntentSeen()

        harness.controller.toggle(using: dependencies)

        try await eventually { harness.insertions == [harness.text] }
    }

    @Test
    func anIntentThatGoesAwayEndsTheGrace() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = harness.dependencies
        dependencies.handoffGrace = .milliseconds(50)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.ownershipIntentSeen()

        harness.controller.ownershipIntentCleared()
        try await Task.sleep(for: .milliseconds(150))

        #expect(harness.controller.phase == .listening)
        #expect(!harness.controller.yieldsToHandoff)
    }

    @Test
    func onlyTheOwnerArmsTheShortcut() throws {
        let suite = "dictation-ownership-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: DictationController.defaultsKey)
        let services = try AppServices(
            arguments: ["-use-temp-store"], environment: [:], defaults: defaults,
            dictation: DictationController(presentsPanel: false))
        #expect(!services.dictationTriggersMayArm)

        services.dictationOwnership.start()

        #expect(services.dictationTriggersMayArm)
    }

    @Test
    func anIntentAfterTheMicrophoneClosedLetsTheSessionFinish() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = harness.dependencies
        dependencies.handoffGrace = .milliseconds(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)

        harness.controller.ownershipIntentSeen()

        try await eventually { harness.insertions == [harness.text] }
    }

    @Test
    func aGraceEndingAfterTheUserFinishedLetsTheSessionFinish() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = harness.dependencies
        dependencies.handoffGrace = .milliseconds(20)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.ownershipIntentSeen()

        harness.controller.toggle(using: dependencies)

        try await eventually { harness.insertions == [harness.text] }
    }

    @Test
    func yieldedWordsSkipPolishSoTheLeaseEndsSoon() async throws {
        let harness = DictationControllerHarness(text: "so we ship it tomorrow")
        defer { harness.controller.cancel() }
        harness.set(DictationTextMode.polish.rawValue, forKey: DictationTextPreferences.modeKey)
        var dependencies = harness.dependencies
        var polished = 0
        dependencies.polishDictation = { text, _, _ in
            polished += 1
            return .polished(text)
        }
        dependencies.handoffGrace = .milliseconds(20)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)

        harness.controller.ownershipIntentSeen()

        try await eventually { harness.controller.phase == .recovery(.ownershipChanged) }
        #expect(polished == 0)
    }

    @Test
    func aSpokenInstructionKeepsItsWordsWhenTheGraceEnds() async throws {
        let port = DictationAdmission.open
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: rewriteDependencies(admission: port))
        try await eventually { controller.phase == .choosing }
        let harness = DictationControllerHarness(text: "make it formal")
        defer { harness.controller.cancel() }
        var dependencies = controller.instructionDependencies(harness.dependencies)
        dependencies.handoffGrace = .milliseconds(20)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)

        harness.controller.ownershipIntentSeen()

        try await eventually { harness.controller.phase == .recovery(.ownershipChanged) }
        #expect(harness.controller.recoveryText == harness.text)
        #expect(controller.spokenInstruction == nil)
    }

    @Test
    func aPreviewGivesUpItsGlobalKeysWhenOwnershipIsLost() async throws {
        var keys: [UInt32: () -> Void] = [:]
        var dependencies = rewriteDependencies(admission: .open)
        dependencies.registerKey = { keyCode, onPress in
            keys[keyCode] = onPress
            return KeyRegistration { keys[keyCode] = nil }
        }
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies)
        try await eventually { controller.phase == .choosing }
        controller.choose(nil)
        try await eventually { controller.phase == .preview("SO WE SHIP IT TOMORROW") }
        #expect(!keys.isEmpty)

        controller.releaseGlobalKeys()

        #expect(keys.isEmpty)
        #expect(controller.result == "SO WE SHIP IT TOMORROW")
    }

    @Test
    func aPreviewFromBeforeAResetCannotReplace() async throws {
        var inserted: [String] = []
        var dependencies = rewriteDependencies(admission: .open)
        dependencies.capture = {
            .success(CapturedSelection(
                text: "so we ship it tomorrow", source: .accessibility, applicationName: "Receiver",
                revalidate: { nil },
                destination: CapturedDictationDestination(name: "Receiver", canRetry: false) { text in
                    inserted.append(text)
                    return .verified
                }))
        }
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies)
        try await eventually { controller.phase == .choosing }
        controller.choose(nil)
        try await eventually { controller.phase == .preview("SO WE SHIP IT TOMORROW") }

        controller.revokeReplace()
        controller.replace()

        guard case .failed = controller.phase else {
            Issue.record("A replace went through after the state was reset")
            return
        }
        #expect(inserted.isEmpty)
    }

    @Test
    func aWorkspaceChangeIsAHintToLookAgain() throws {
        let scratch = Scratch()
        let peer = Preference()
        peer.isOn.withLock { $0 = true }
        let ownership = DictationOwnership(
            participant: Self.portavoz, root: scratch.root,
            conditions: {
                ParticipantConditions(
                    preferenceIsOn: true, missingForReadiness: nil, legacyPeerIsActive: peer.isOn.withLock { $0 })
            },
            notificationName: "app.portavoz.ownership-tests.\(scratch.root.lastPathComponent)")
        let coordinator = DictationOwnershipCoordinator(ownership: ownership) {}
        coordinator.start()
        #expect(coordinator.state == .unavailable(.legacyPeerActive))
        peer.isOn.withLock { $0 = false }

        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        #expect(coordinator.state == .owned)
    }

    private final class KeyRegistration: GlobalHotkeyRegistration {
        let onUnregister: () -> Void
        init(onUnregister: @escaping () -> Void) { self.onUnregister = onUnregister }
        func unregister() { onUnregister() }
    }

    private func rewriteDependencies(admission: DictationAdmission) -> SelectionRewriteController.Dependencies {
        SelectionRewriteController.Dependencies(
            admission: admission,
            capture: {
                .success(CapturedSelection(
                    text: "so we ship it tomorrow", source: .accessibility, applicationName: "Receiver",
                    revalidate: { nil },
                    destination: CapturedDictationDestination(name: "Receiver", canRetry: false) { _ in .verified }))
            },
            polish: { text, _, _ in .polished(text.uppercased()) },
            recipes: { [] }, protectedTerms: { [] }, copyText: { _ in true },
            wait: { _ in try await Task.sleep(for: .seconds(3_600)) })
    }

    @Test
    func aPressRightAfterCancelIsRefusedUntilStopHasDrained() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        var dependencies = harness.dependencies
        dependencies.admission = coordinator.admission
        let stop = StopGate()
        await harness.microphone.holdStop { await stop.wait() }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.controller.cancel()

        harness.controller.toggle(using: dependencies)

        #expect(harness.controller.phase == .idle)
        #expect(coordinator.holdsLease)
        stop.open()
        try await eventually { !coordinator.holdsLease }
        harness.controller.toggle(using: dependencies)
        #expect(harness.controller.phase != .idle)
        await harness.microphone.holdStop {}
        harness.controller.cancel()
        try await eventually { !coordinator.holdsLease }
    }

    private final class StopGate: Sendable {
        private let opened = Mutex(false)

        func open() { opened.withLock { $0 = true } }

        func wait() async {
            while !opened.withLock({ $0 }) {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    @Test
    func aHeldTriggerKeepsItsWordsWhenAHandoffDisarmsIt() async throws {
        let suite = "dictation-ownership-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:], defaults: defaults)
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = harness.dependencies
        dependencies.handoffGrace = .seconds(3_600)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.modifierTrigger.ownsSession = true
        harness.controller.ownershipIntentSeen()

        harness.controller.syncModifierPTT(services: services)

        try await eventually { harness.controller.phase == .recovery(.ownershipChanged) }
        #expect(harness.controller.recoveryText == harness.text)
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func aHeldTriggerStillCancelsWhenItIsDisabledWithNoHandoff() async throws {
        let suite = "dictation-ownership-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = try AppServices(arguments: ["-use-temp-store"], environment: [:], defaults: defaults)
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        harness.controller.toggle(using: harness.dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.controller.modifierTrigger.ownsSession = true

        harness.controller.syncModifierPTT(services: services)

        #expect(harness.controller.phase == .idle)
    }

    @Test
    func anIntentCancelsAPracticeSessionEvenWhileItDelivers() async throws {
        let harness = DictationControllerHarness(text: "Hola")
        let practice = DictationPracticeField()
        practice.show(UUID(), isKey: true)
        var dependencies = practice.route(harness.dependencies, appIsActive: true)
        let delivery = PreparationGate()
        dependencies.captureDestination = {
            CapturedDictationDestination(name: "Practice", canRetry: false) { _ in
                await delivery.wait()
                return .verified
            }
        }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == "Hola" }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.phase == .delivering && delivery.started }

        harness.controller.ownershipIntentSeen()

        #expect(harness.controller.phase == .idle)
        delivery.release()
    }

    private func previewRewrite(
        admission: DictationAdmission, insertions: @escaping (String) -> Void
    ) async throws -> SelectionRewriteController {
        let controller = SelectionRewriteController(presentsPanel: false)
        controller.start(using: SelectionRewriteController.Dependencies(
            admission: admission,
            capture: {
                .success(CapturedSelection(
                    text: "so we ship it tomorrow", source: .accessibility, applicationName: "Receiver",
                    revalidate: { nil },
                    destination: CapturedDictationDestination(name: "Receiver", canRetry: false) { text in
                        insertions(text)
                        return .verified
                    }))
            },
            polish: { text, _, _ in .polished(text.uppercased()) },
            recipes: { [] }, protectedTerms: { [] }, copyText: { _ in true },
            wait: { _ in try await Task.sleep(for: .seconds(3_600)) }))
        try await eventually { controller.phase == .choosing }
        controller.choose(nil)
        try await eventually { controller.phase == .preview("SO WE SHIP IT TOMORROW") }
        return controller
    }

    @Test
    func aHandoffCompletesWithARewritePreviewOpenAndTheReplaceIsRefused() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        var inserted: [String] = []
        let rewrite = try await previewRewrite(admission: coordinator.admission) { inserted.append($0) }
        defer { rewrite.cancel() }

        let outcome = await scratch.participant(Self.other).takeOwnership(userConfirmed: true, triggers: Triggers())

        #expect(outcome == .completed(generation: 2))
        rewrite.replace()
        guard case .failed = rewrite.phase else {
            Issue.record("A replace went through for a former owner")
            return
        }
        #expect(inserted.isEmpty)
        #expect(rewrite.result == "SO WE SHIP IT TOMORROW")
    }

    @Test
    func aHandoffThereAndBackWithARewritePreviewOpenRefusesTheReplace() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        var inserted: [String] = []
        let rewrite = try await previewRewrite(admission: coordinator.admission) { inserted.append($0) }
        defer { rewrite.cancel() }
        let portavoz = try #require(scratch.lastOwnership)
        #expect(await scratch.participant(Self.other)
            .takeOwnership(userConfirmed: true, triggers: Triggers()) == .completed(generation: 2))
        #expect(await portavoz.takeOwnership(userConfirmed: true, triggers: Triggers()) == .completed(generation: 3))

        rewrite.replace()

        guard case .failed = rewrite.phase else {
            Issue.record("A replace went through across a handoff there and back")
            return
        }
        #expect(inserted.isEmpty)
    }

    @Test
    func anOwnerChangeBeforeDeliveryKeepsTheWordsInRecovery() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = harness.dependencies
        dependencies.admission = DictationAdmission(
            acquire: { _ in .success(DictationLease(revalidate: { false })) }, isEligible: { true })

        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)

        try await eventually { harness.controller.phase == .recovery(.ownershipChanged) }
        #expect(harness.controller.recoveryText == harness.text)
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func anOwnerChangeBeforeAReplayKeepsTheWordsInRecovery() async throws {
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var isOwner = true
        var dependencies = harness.dependencies
        dependencies.admission = DictationAdmission(
            acquire: { _ in .success(DictationLease(revalidate: { isOwner })) }, isEligible: { true })
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.insertions.count == 1 && !harness.controller.isActive }
        isOwner = false

        harness.controller.pasteLastDictation(using: dependencies)

        try await eventually { harness.controller.phase == .recovery(.ownershipChanged) }
        #expect(harness.insertions.count == 1)
    }

    @Test
    func aRewriteReplaceIsRefusedAfterAHandoffThereAndBack() async throws {
        var generation = 1
        var insertions: [String] = []
        let dependencies = SelectionRewriteController.Dependencies(
            admission: DictationAdmission(
                acquire: { _ in .success(DictationLease(generation: generation)) }, isEligible: { true }),
            capture: {
                .success(CapturedSelection(
                    text: "so we ship it tomorrow", source: .accessibility, applicationName: "Receiver",
                    revalidate: { nil },
                    destination: CapturedDictationDestination(name: "Receiver", canRetry: false) { text in
                        insertions.append(text)
                        return .verified
                    }))
            },
            polish: { text, _, _ in .polished(text.uppercased()) },
            recipes: { [] }, protectedTerms: { [] }, copyText: { _ in true },
            wait: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies)
        try await eventually { controller.phase == .choosing }
        controller.choose(nil)
        try await eventually { controller.phase == .preview("SO WE SHIP IT TOMORROW") }
        generation = 3

        controller.replace()

        guard case .failed = controller.phase else {
            Issue.record("A replace went through after the owner changed")
            return
        }
        #expect(insertions.isEmpty)
        #expect(controller.result == "SO WE SHIP IT TOMORROW")
    }
}
