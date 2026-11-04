import AppKit
import Darwin
import DictationOwnership
import Foundation
import Testing

@testable import portavoz_app
@testable import PortavozTestSupport

/// The acceptance rows for two apps on one Mac: the real coordinator here, another app in its own
/// process, and the real locks in a scratch folder. Triggers and the microphone are test doubles.
@Suite(.serialized, .exclusiveArgumentDomain, .timeLimit(.minutes(1)))
@MainActor
struct DictationCoexistenceTests: CoexistenceSuite {
    // MARK: Launch

    @Test(arguments: 1...5)
    func twoFirstRunClaimsAtOnceLeaveOneOwnerAndOneAdmission(round: Int) async throws {
        let mac = try CoexistenceMac()
        let peer = try mac.launchPeer(as: CoexistenceID.otherClaimant)
        try await peer.send("status")

        try peer.post("claim")
        try await Task.sleep(for: .microseconds(round * 50))
        let coordinator = mac.launchPortavoz()
        let claim = try await peer.reply()
        coordinator.reevaluate()

        #expect(["changed(generation: 1)", "noChange", "busy"].contains(claim))
        let state = try mac.state()
        #expect(state.generation == 1)
        #expect([CoexistenceID.portavoz, CoexistenceID.otherClaimant].contains(state.owner))
        #expect(try await admissions(coordinator, peer) == 1)
    }

    @Test(arguments: 1...5)
    func aFirstRunClaimRacingAHandoffLeavesOneOwnerAndOneAdmission(round: Int) async throws {
        let mac = try CoexistenceMac()
        let peer = try mac.launchPeer()
        try await peer.send("status")

        try peer.post("take")
        try await Task.sleep(for: .microseconds(round * 50))
        let coordinator = mac.launchPortavoz()
        _ = try await peer.reply()
        try await eventually {
            coordinator.reevaluate()
            return coordinator.state == .owned || coordinator.state == .available
        }

        let state = try mac.state()
        #expect([CoexistenceID.portavoz, CoexistenceID.secreteo].contains(state.owner))
        #expect(state.intent == nil)
        #expect(try await admissions(coordinator, peer) == 1)
    }

    @Test
    func anOwningPeerKeepsAPortavozLaunchFromArming() async throws {
        let mac = try CoexistenceMac()
        _ = try await mac.launchOwningPeer()

        let coordinator = mac.launchPortavoz()

        #expect(coordinator.state == .available)
        #expect(!coordinator.armsTriggers)
        #expect(coordinator.ownerStatus == .otherApp(identifier: CoexistenceID.secreteo))
        #expect(refusal(coordinator) == .notOwner)
        #expect(try mac.state().owner == CoexistenceID.secreteo)
    }

    // MARK: Toggling and going back

    @Test
    func aToggleThereAndBackCountsEachChangeAndNamesThePreviousOwner() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        #expect(coordinator.state == .owned)
        #expect(try mac.state().generation == 1)

        let there = try await peer.send("take")
        try await eventually { coordinator.state == .available }

        #expect(there == "completed(generation: 2)")
        #expect(!coordinator.armsTriggers)
        #expect(refusal(coordinator) == .notOwner)
        #expect(try mac.state().previous == CoexistenceID.portavoz)

        await mac.comeBack(coordinator)

        #expect(coordinator.state == .owned)
        #expect(mac.armed == 1)
        #expect(try mac.state().generation == 3)
        #expect(try mac.state().previous == CoexistenceID.secreteo)
        #expect(try await peer.send("status") == "available")
        #expect(try await peer.send("acquire global").hasPrefix("refused notOwner"))
    }

    @Test
    func aHandoffWaitsForAPeerSessionThatYields() async throws {
        let mac = try CoexistenceMac()
        let peer = try await mac.launchOwningPeer()
        let coordinator = mac.launchPortavoz()
        #expect(try await peer.send("acquire global") == "admitted 1")
        try await peer.send("yield-on-intent")
        #expect(refusal(coordinator) == .busy)

        await mac.comeBack(coordinator)

        #expect(coordinator.handoffProblem == nil)
        #expect(coordinator.state == .owned)
        #expect(try mac.state().generation == 2)
    }

    @Test
    func aPeerThatNeverLetsGoTimesOutAndChangesNothing() async throws {
        let mac = try CoexistenceMac()
        let peer = try await mac.launchOwningPeer()
        let coordinator = mac.launchPortavoz(deadline: .milliseconds(100))
        #expect(try await peer.send("acquire global") == "admitted 1")

        await mac.comeBack(coordinator)

        #expect(coordinator.handoffProblem == .busy)
        #expect(coordinator.state == .available)
        #expect(mac.armed == 0)
        #expect(mac.disarmed == 1)
        let state = try mac.state()
        #expect(state.owner == CoexistenceID.secreteo)
        #expect(state.generation == 1)
        #expect(state.intent == nil)
        #expect(try await peer.send("revalidate") == "true")
    }

    // MARK: A Portavoz session when the peer asks for ownership

    @Test
    func aSessionStillPreparingIsCancelledAndThePeerTakesOver() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        var dependencies = connect(harness, to: coordinator)
        dependencies.authorizeMicrophone = {
            try? await Task.sleep(for: .seconds(3_600))
            return false
        }
        harness.controller.toggle(using: dependencies)
        #expect(harness.controller.phase == .preparing)

        let handoff = try await peer.send("take")

        #expect(handoff == "completed(generation: 2)")
        #expect(harness.controller.phase == .idle)
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func aListeningSessionKeepsItsWordsAndNeverPastesLate() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = connect(harness, to: coordinator)
        dependencies.handoffGrace = .milliseconds(50)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)

        let handoff = try await peer.send("take")

        #expect(handoff == "completed(generation: 2)")
        try await eventually { harness.controller.phase == .recovery(.ownershipChanged) }
        #expect(harness.controller.recoveryText == harness.text)
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func aDeliveryRunsToTheEndOnceAndTheHandoffWaitsForTheClipboard() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        let gate = PreparationGate()
        mac.settle = { await gate.wait() }
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        let dependencies = connect(harness, to: coordinator)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { gate.started }

        let handoff = Task { try await peer.send("take") }
        try await eventually { coordinator.state == .transferring }

        #expect(harness.insertions == [harness.text])
        #expect(refusal(coordinator) == .transferring)
        gate.release()
        #expect(try await handoff.value == "completed(generation: 2)")
        #expect(harness.insertions == [harness.text])
    }

    @Test
    func aDeliveryOutlastingThePeersDeadlineFinishesAndKeepsOwnership() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer(deadline: .milliseconds(100))
        let gate = PreparationGate()
        mac.settle = { await gate.wait() }
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        let dependencies = connect(harness, to: coordinator)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)
        harness.controller.toggle(using: dependencies)
        try await eventually { gate.started }

        let handoff = try await peer.send("take")

        #expect(handoff == "timedOut")
        let state = try mac.state()
        #expect(state.owner == CoexistenceID.portavoz)
        #expect(state.generation == 1)
        #expect(state.intent == nil)
        #expect(harness.insertions == [harness.text])
        gate.release()
        try await eventually { !coordinator.holdsLease }
        #expect(refusal(coordinator) == nil)
    }

    @Test
    func aSessionSeesTheIntentWithinASecondWhenTheNotificationIsMissed() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer(notification: "app.portavoz.coexistence-tests.\(UUID().uuidString)")
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = connect(harness, to: coordinator)
        dependencies.handoffGrace = .milliseconds(50)
        harness.controller.toggle(using: dependencies)
        try await eventually { harness.controller.partialText == harness.text }
        harness.now = harness.now.addingTimeInterval(1)

        let handoff = try await peer.send("take")

        #expect(handoff == "completed(generation: 2)")
        try await eventually { harness.controller.phase == .recovery(.ownershipChanged) }
        #expect(harness.insertions.isEmpty)
    }

    @Test
    func aReleaseAfterAPressRefusedByThePeerLeavesItsSessionAlone() async throws {
        let mac = try CoexistenceMac()
        let peer = try await mac.launchOwningPeer()
        let coordinator = mac.launchPortavoz()
        #expect(try await peer.send("acquire global") == "admitted 1")
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        let dependencies = connect(harness, to: coordinator)

        harness.controller.handleHotkeyPress(using: dependencies, at: harness.now)
        harness.controller.handleHotkeyRelease(at: harness.now.addingTimeInterval(5))

        #expect(harness.controller.phase == .idle)
        #expect(harness.insertions.isEmpty)
        #expect(await harness.microphone.starts == 0)
        #expect(try await peer.send("revalidate") == "true")
    }

    // MARK: Crashes

    @Test
    func aPeerKilledWhileHoldingItsLeaseKeepsOwnershipUntilTheUserChooses() async throws {
        let mac = try CoexistenceMac()
        let peer = try await mac.launchOwningPeer()
        let coordinator = mac.launchPortavoz()
        #expect(try await peer.send("acquire global") == "admitted 1")

        await peer.crash()
        coordinator.reevaluate()

        #expect(refusal(coordinator) == .notOwner)
        #expect(coordinator.ownerStatus == .otherApp(identifier: CoexistenceID.secreteo))
        #expect(!coordinator.armsTriggers)
        #expect(try mac.state().owner == CoexistenceID.secreteo)

        await mac.comeBack(coordinator)

        #expect(coordinator.state == .owned)
        #expect(try mac.state().generation == 2)
    }

    @Test
    func aPeerKilledDuringPracticeFreesTheLockForTheOwner() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        #expect(try await peer.send("acquire practice") == "admitted 1")
        #expect(refusal(coordinator) == .busy)

        await peer.crash()

        #expect(refusal(coordinator) == nil)
    }

    @Test
    func aPeerKilledBeforeItsCommitLeavesPortavozTheOwnerOnceTheIntentExpires() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()

        _ = try? await peer.send("take-and-die-arming")
        await peer.crash()
        coordinator.reevaluate()
        try await eventually { coordinator.state == .transferring }
        #expect(refusal(coordinator) == .transferring)

        mac.clockOffset.value = OwnershipIntent.lifetime + 1
        coordinator.reevaluate()

        try await eventually { coordinator.state == .owned }
        let state = try mac.state()
        #expect(state.owner == CoexistenceID.portavoz)
        #expect(state.generation == 1)
        #expect(refusal(coordinator) == nil)
    }

    @Test
    func aPeerKilledAfterItsCommitStaysTheOwner() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        try await peer.send("take")

        await peer.crash()
        try await eventually { coordinator.state == .available }

        #expect(!coordinator.armsTriggers)
        #expect(try mac.state().owner == CoexistenceID.secreteo)
        #expect(refusal(coordinator) == .notOwner)
    }
}
