import DictationOwnership
import Foundation
import PortavozCore
import Testing

@testable import portavoz_app
@testable import PortavozTestSupport

// The controller harness overrides process-wide NSArgumentDomain.
@Suite(.serialized, .exclusiveArgumentDomain, .timeLimit(.minutes(1)))
@MainActor
struct DictationOwnerStatusTests {
    private static let portavoz = "app.portavoz.mac"
    private static let secreteo = "com.johnny4young.secreteo"

    private struct Triggers: OwnershipTriggers {
        func arm() async -> Bool { true }
        func disarm() async {}
    }

    @MainActor
    private final class Scratch {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-owner-\(UUID().uuidString)", isDirectory: true)

        func participant(_ identifier: String, deadline: Duration = .seconds(10)) -> DictationOwnership {
            DictationOwnership(
                participant: identifier, root: root,
                conditions: {
                    ParticipantConditions(preferenceIsOn: true, missingForReadiness: nil, legacyPeerIsActive: false)
                },
                notificationName: "app.portavoz.owner-tests.\(root.lastPathComponent)",
                timings: OwnershipTimings(
                    changeDeadline: deadline, capturePoll: .milliseconds(5), armRetry: .milliseconds(5)))
        }

        func coordinator(deadline: Duration = .seconds(10)) -> DictationOwnershipCoordinator {
            DictationOwnershipCoordinator(
                ownership: participant(DictationOwnerStatusTests.portavoz, deadline: deadline), root: root) {}
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        _ = await TestPolling.until(condition)
        try #require(condition())
    }

    @Test(arguments: [
        (ParticipantState.owned, nil as String?, DictationOwnerStatus.ownedHere),
        (.off, "com.johnny4young.secreteo", .ownedHere),
        (.available, "com.johnny4young.secreteo", .otherApp(identifier: "com.johnny4young.secreteo")),
        (.available, nil, .nobody),
        (.transferring, nil, .switching),
        (.unavailable(.legacyPeerActive), nil, .olderBuildActive),
        (.unavailable(.corruptState), nil, .damaged),
        (.unavailable(.newerProtocol), nil, .needsUpdate),
        (.unavailable(.ioError), nil, .unavailable),
    ])
    func eachStateSaysOneThing(_ example: (ParticipantState, String?, DictationOwnerStatus)) {
        #expect(DictationOwnerStatus(state: example.0, owner: example.1) == example.2)
    }

    @Test
    func onlyAKnownOwnerIsNamedAndOnlyAWayBackIsOffered() throws {
        let known = try #require(DictationOwnerStatus.otherApp(identifier: Self.secreteo).message)
        #expect(known.contains("Secreteo"))
        let unknown = try #require(DictationOwnerStatus.otherApp(identifier: "com.example.other").message)
        #expect(!unknown.contains("com.example"))
        #expect(DictationOwnerStatus.ownedHere.message == nil)
        #expect(DictationOwnerStatus.nobody.offersToComeBack)
        #expect(!DictationOwnerStatus.damaged.offersToComeBack)
        #expect(!DictationOwnerStatus.switching.offersToComeBack)
    }

    @Test
    func aDisposableLaunchStartsFromTheOwnerItAskedFor() {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()

        coordinator.seedForUITests(arguments: ["-seed-dictation-owner-secreteo"])
        coordinator.start()

        #expect(coordinator.ownerStatus == .otherApp(identifier: Self.secreteo))
        #expect(!coordinator.armsTriggers)
    }

    @Test
    func comingBackTakesOwnershipFromAnOwnerThatQuit() async {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        coordinator.seedForUITests(arguments: ["-seed-dictation-owner-secreteo"])
        coordinator.start()
        var armed = 0

        await coordinator.comeBack(arm: { armed += 1; return true }, disarm: {})

        #expect(coordinator.state == .owned)
        #expect(coordinator.owner == Self.portavoz)
        #expect(coordinator.handoffProblem == nil)
        #expect(armed > 0)
    }

    @Test
    func comingBackFromNobodyWorksToo() async {
        let scratch = Scratch()
        let ownership = DictationOwnership(
            participant: "app.portavoz.mac.dev", root: scratch.root,
            conditions: {
                ParticipantConditions(preferenceIsOn: true, missingForReadiness: nil, legacyPeerIsActive: false)
            },
            notificationName: "app.portavoz.owner-tests.\(scratch.root.lastPathComponent)")
        let coordinator = DictationOwnershipCoordinator(ownership: ownership, root: scratch.root) {}
        coordinator.start()
        #expect(coordinator.ownerStatus == .nobody, "A Dev build never claims by itself")

        await coordinator.comeBack(arm: { true }, disarm: {})

        #expect(coordinator.state == .owned)
    }

    @Test
    func aHandoffThatTimesOutSaysSoAndChangesNothing() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator(deadline: .milliseconds(50))
        coordinator.seedForUITests(arguments: ["-seed-dictation-owner-secreteo"])
        coordinator.start()
        guard case .admitted(let held) = scratch.participant(Self.secreteo).acquire(.global) else {
            Issue.record("The other app could not take the lock")
            return
        }
        defer { held.release() }

        await coordinator.comeBack(arm: { true }, disarm: {})

        #expect(coordinator.handoffProblem == .busy)
        #expect(coordinator.ownerStatus == .otherApp(identifier: Self.secreteo))
    }

    @Test(arguments: [
        (HandoffOutcome.completed(generation: 2), nil as DictationHandoffProblem?),
        (.alreadyOwner, nil),
        (.timedOut, .busy),
        (.busy, .busy),
        (.triggerConflict, .shortcutConflict),
        (.ioError, .failed),
        (.cancelled, .failed),
    ])
    func eachHandoffOutcomeMapsToOneProblem(_ example: (HandoffOutcome, DictationHandoffProblem?)) {
        #expect(DictationHandoffProblem(example.0) == example.1)
    }

    @Test
    func resettingDamagedStateLeavesNobodyAndAWayBack() async {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        coordinator.seedForUITests(arguments: ["-seed-dictation-ownership-damaged"])
        coordinator.start()
        #expect(coordinator.ownerStatus == .damaged)
        #expect(throws: DictationAdmissionRefusal.unavailable(.corruptState)) {
            try coordinator.admission.acquire(.global).get()
        }

        await coordinator.resetDamagedState()

        #expect(coordinator.ownerStatus == .nobody)
        await coordinator.comeBack(arm: { true }, disarm: {})
        #expect(coordinator.state == .owned)
    }

    @Test(arguments: [
        (DictationAdmissionRefusal.dictationOff, PortavozAppIntentBridge.DictationRequestOutcome.dictationOff),
        (.notOwner, .otherAppOwnsDictation),
        (.unavailable(.ioError), .dictationUnavailable),
        (.busy, .busy),
        (.transferring, .busy),
    ])
    func anIntentSaysWhyItWasRefused(
        _ example: (DictationAdmissionRefusal, PortavozAppIntentBridge.DictationRequestOutcome)
    ) {
        #expect(PortavozAppDelegate.dictationIntentOutcome(
            for: .toggle, refusal: example.0, phase: .idle, hasPastableText: true) == example.1)
    }

    @Test
    func aRefusedReinsertExplainsItselfAndLeavesOnlyCopy() async throws {
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        defer { harness.controller.cancel() }
        var refusal: DictationAdmissionRefusal?
        var dependencies = harness.dependencies
        dependencies.admission = DictationAdmission(
            acquire: { _ in refusal.map { .failure($0) } ?? .success(DictationLease()) }, isEligible: { true })
        dependencies.captureDestination = {
            CapturedDictationDestination(name: "Receiver", canRetry: true) { _ in .refused(.targetChanged) }
        }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.phase == .recovery(.targetChanged) }
        #expect(harness.controller.canRetryDelivery)

        refusal = .busy
        harness.controller.retryUndeliveredText()
        #expect(harness.controller.phase == .recovery(.targetChanged), "Busy passes in a moment")

        refusal = .notOwner
        harness.controller.retryUndeliveredText()

        #expect(harness.controller.phase == .recovery(.ownershipChanged))
        #expect(harness.controller.recoveryText == harness.text)
        #expect(!harness.controller.canRetryDelivery)
    }

    @Test
    func aRefusedSayHowExplainsItselfAndKeepsTheChoices() async throws {
        var refusal: DictationAdmissionRefusal?
        var started = 0
        var dependencies = SelectionRewriteController.Dependencies(
            admission: DictationAdmission(
                acquire: { _ in refusal.map { .failure($0) } ?? .success(DictationLease()) }, isEligible: { true }),
            capture: {
                .success(CapturedSelection(
                    text: "so we ship it tomorrow", source: .accessibility, applicationName: "Receiver",
                    revalidate: { nil },
                    destination: CapturedDictationDestination(name: "Receiver", canRetry: false) { _ in .verified }))
            },
            polish: { text, _, _ in .polished(text) },
            recipes: { [] }, protectedTerms: { [] }, copyText: { _ in true })
        dependencies.startDictation = { started += 1 }
        let controller = SelectionRewriteController(presentsPanel: false)
        defer { controller.cancel() }
        controller.start(using: dependencies)
        try await eventually { controller.phase == .choosing }
        refusal = .notOwner

        controller.sayHow()

        #expect(started == 0)
        #expect(controller.phase == .choosing)
        #expect(controller.notice == DictationAdmissionRefusal.notOwner.message)

        refusal = nil
        controller.sayHow()

        #expect(started == 1)
    }
}
