import DictationOwnership
import Foundation
import PortavozCore
import Testing
import notify

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
        (ParticipantState.owned, nil as String?, DictationOwnerStatus.noNotice),
        (.off, "com.johnny4young.secreteo", .noNotice),
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
        #expect(DictationOwnerStatus.noNotice.message == nil)
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

    @Test
    func aNonOwnerWithDictationOffIsToldDictationIsOff() throws {
        let scratch = Scratch()
        let ownership = DictationOwnership(
            participant: Self.portavoz, root: scratch.root,
            conditions: {
                ParticipantConditions(preferenceIsOn: false, missingForReadiness: nil, legacyPeerIsActive: false)
            },
            notificationName: "app.portavoz.owner-tests.\(scratch.root.lastPathComponent)")
        let coordinator = DictationOwnershipCoordinator(ownership: ownership, root: scratch.root) {}
        coordinator.start()

        #expect(throws: DictationAdmissionRefusal.dictationOff) { try coordinator.admission.acquire(.global).get() }
    }

    @Test
    func anOwnerThatTurnsOffUpdatesTheRowWithNoStateChange() async throws {
        let scratch = Scratch()
        let name = "app.portavoz.owner-tests.\(scratch.root.lastPathComponent)"
        let coordinator = DictationOwnershipCoordinator(
            ownership: scratch.participant(Self.portavoz), root: scratch.root, notificationName: name) {}
        coordinator.seedForUITests(arguments: ["-seed-dictation-owner-secreteo"])
        coordinator.start()
        #expect(coordinator.ownerStatus == .otherApp(identifier: Self.secreteo))
        // The observer's first report reads the owner too, so it has to land before the change.
        try await Task.sleep(for: .milliseconds(300))
        let state = OwnershipState(owner: nil, generation: 2, previous: Self.secreteo, intent: nil)
        try JSONEncoder().encode(state)
            .write(to: scratch.root.appendingPathComponent("ownership.json"), options: .atomic)

        notify_post(name)

        try await eventually { coordinator.ownerStatus == .nobody }
    }

    @Test
    func theMenuOffersDictationOnlyAfterTheHandoffCommits() async {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        coordinator.seedForUITests(arguments: ["-seed-dictation-owner-secreteo"])
        coordinator.start()
        var offeredWhileArming: Bool?

        await coordinator.comeBack(
            arm: {
                offeredWhileArming = coordinator.offersDictationActions
                return true
            },
            disarm: {})

        #expect(offeredWhileArming == false)
        #expect(coordinator.offersDictationActions)
    }

    @Test
    func aSecondClickDoesNotDisturbTheHandoffInFlight() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator()
        coordinator.seedForUITests(arguments: ["-seed-dictation-owner-secreteo"])
        coordinator.start()
        guard case .admitted(let held) = scratch.participant(Self.secreteo).acquire(.global) else {
            Issue.record("The other app could not take the lock")
            return
        }
        let first = Task { await coordinator.comeBack(arm: { true }, disarm: {}) }
        try await eventually {
            coordinator.reevaluate()
            return coordinator.state == .transferring
        }

        await coordinator.comeBack(arm: { true }, disarm: {})

        #expect(coordinator.handoffProblem == nil)
        held.release()
        await first.value
        #expect(coordinator.state == .owned)
    }

    @Test
    func aHandoffProblemGoesAwayWhenTheStateMovesOn() async throws {
        let scratch = Scratch()
        let coordinator = scratch.coordinator(deadline: .milliseconds(50))
        coordinator.seedForUITests(arguments: ["-seed-dictation-owner-secreteo"])
        coordinator.start()
        guard case .admitted(let held) = scratch.participant(Self.secreteo).acquire(.global) else {
            Issue.record("The other app could not take the lock")
            return
        }
        await coordinator.comeBack(arm: { true }, disarm: {})
        held.release()
        #expect(coordinator.handoffProblem == .busy)
        try Data("{".utf8).write(to: scratch.root.appendingPathComponent("ownership.json"), options: .atomic)

        coordinator.reevaluate()

        #expect(coordinator.ownerStatus == .damaged)
        #expect(coordinator.handoffProblem == nil)
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

    @Test
    func aRefusedReinsertSaysWhyAndCanStillRunLater() async throws {
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        defer { harness.controller.cancel() }
        var refusal: DictationAdmissionRefusal?
        var accepts = false
        var delivered: [String] = []
        var dependencies = harness.dependencies
        dependencies.admission = DictationAdmission(
            acquire: { _ in refusal.map { .failure($0) } ?? .success(DictationLease()) }, isEligible: { true })
        dependencies.captureDestination = {
            CapturedDictationDestination(name: "Receiver", canRetry: true) { text in
                guard accepts else { return .refused(.targetChanged) }
                delivered.append(text)
                return .verified
            }
        }
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.phase == .recovery(.targetChanged) }

        refusal = .transferring
        harness.controller.retryUndeliveredText()

        #expect(harness.controller.phase == .recovery(.targetChanged), "Its real failure stays")
        #expect(harness.controller.retryRefusal == .transferring)
        #expect(harness.controller.recoveryText == harness.text)
        #expect(harness.controller.canRetryDelivery)

        refusal = nil
        accepts = true
        harness.controller.retryUndeliveredText()

        #expect(harness.controller.retryRefusal == nil)
        try await eventually { delivered == [harness.text] }
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
