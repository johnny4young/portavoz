import AppKit
import Darwin
import DictationOwnership
import Foundation
import Testing

@testable import portavoz_app
@testable import PortavozTestSupport

/// The rows about time and installation: sleep, upgrade, uninstall, readiness, Dev and Release,
/// an older Portavoz, and sessions in both processes across handoffs.
@Suite(.serialized, .exclusiveArgumentDomain, .timeLimit(.minutes(1)))
@MainActor
struct DictationCoexistenceLifecycleTests: CoexistenceSuite {
    // MARK: Sleep and wake

    @Test
    func aPeerFrozenWithItsLeaseStaysExclusiveAndCarriesOn() async throws {
        let mac = try CoexistenceMac()
        let peer = try await mac.launchOwningPeer()
        let coordinator = mac.launchPortavoz(deadline: .milliseconds(100))
        #expect(try await peer.send("acquire global") == "admitted 1")

        peer.signal(SIGSTOP)
        defer { peer.signal(SIGCONT) }
        await mac.comeBack(coordinator)
        #expect(coordinator.handoffProblem == .busy)
        peer.signal(SIGCONT)

        #expect(try await peer.send("revalidate") == "true")
        #expect(try mac.state().owner == CoexistenceID.secreteo)
    }

    @Test
    func anIntentThatExpiredDuringSleepIsIgnoredOnWake() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let intent = OwnershipIntent(from: CoexistenceID.portavoz, to: CoexistenceID.secreteo, now: Date())
        let state = OwnershipState(owner: CoexistenceID.portavoz, generation: 1, previous: nil, intent: intent)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: mac.stateFile, options: .atomic)
        coordinator.reevaluate()
        try await eventually { coordinator.state == .transferring }

        mac.clockOffset.value = OwnershipIntent.lifetime + 1
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)

        try await eventually { coordinator.state == .owned }
        #expect(refusal(coordinator) == nil)
    }

    @Test
    func anIntentLeftByACrashExpiresWithNoOtherEvent() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let createdAt = Date().addingTimeInterval(1.5 - OwnershipIntent.lifetime)
        let intent = OwnershipIntent(from: CoexistenceID.portavoz, to: CoexistenceID.secreteo, now: createdAt)
        let state = OwnershipState(owner: CoexistenceID.portavoz, generation: 1, previous: nil, intent: intent)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: mac.stateFile, options: .atomic)
        coordinator.reevaluate()
        #expect(coordinator.state == .transferring)

        try await eventually { coordinator.state == .owned }

        #expect(refusal(coordinator) == nil)
    }

    // MARK: Upgrade and uninstall

    @Test
    func aRelaunchKeepsTheOwnerWhicheverAppItIs() async throws {
        let mac = try CoexistenceMac()
        var coordinator = mac.launchPortavoz()
        #expect(coordinator.state == .owned)
        coordinator = mac.launchPortavoz()
        #expect(coordinator.state == .owned)
        let peer = try mac.launchPeer()
        try await peer.send("take")

        coordinator = mac.launchPortavoz()

        #expect(coordinator.state == .available)
        #expect(try mac.state().owner == CoexistenceID.secreteo)
        #expect(try mac.state().generation == 2)
    }

    @Test
    func aNewerStateFileFailsClosedAndStaysByteIdentical() async throws {
        let mac = try CoexistenceMac()
        let newer = Data(#"{"version":2,"owner":"com.example.future","generation":9}"#.utf8)
        try newer.write(to: mac.stateFile)
        let peer = try mac.launchPeer()

        let coordinator = mac.launchPortavoz()

        #expect(coordinator.state == .unavailable(.newerProtocol))
        #expect(coordinator.ownerStatus == .needsUpdate)
        #expect(refusal(coordinator) == .unavailable(.newerProtocol))
        #expect(try await peer.send("acquire global").hasPrefix("refused"))
        #expect(try Data(contentsOf: mac.stateFile) == newer)
    }

    @Test
    func anUninstalledPeerStaysOnRecordAndOnlyTheUserMovesOwnership() async throws {
        let mac = try CoexistenceMac()
        let peer = try await mac.launchOwningPeer()
        _ = mac.launchPortavoz()

        await peer.crash()
        let relaunched = mac.launchPortavoz()

        #expect(relaunched.state == .available)
        #expect(relaunched.ownerStatus == .otherApp(identifier: CoexistenceID.secreteo))
        #expect(relaunched.ownerStatus.offersToComeBack)
        #expect(!relaunched.armsTriggers)
        #expect(try mac.state().owner == CoexistenceID.secreteo)

        await mac.comeBack(relaunched)

        #expect(relaunched.state == .owned)
        #expect(mac.armed == 1)
    }

    @Test
    func anUninstalledPeerWithDictationOffHereOffersNothing() async throws {
        let mac = try CoexistenceMac()
        mac.conditions.value.preferenceIsOn = false
        let peer = try await mac.launchOwningPeer()

        await peer.crash()
        let coordinator = mac.launchPortavoz()

        #expect(coordinator.state == .off)
        #expect(coordinator.ownerStatus == .noNotice)
        try await eventually { refusal(coordinator) == .dictationOff }
        #expect(mac.armed == 0)
        #expect(try mac.state().owner == CoexistenceID.secreteo)
    }

    @Test
    func aPeerTurningOffLeavesNobodyAndPortavozDoesNotArmItself() async throws {
        let mac = try CoexistenceMac()
        let peer = try await mac.launchOwningPeer()
        let coordinator = mac.launchPortavoz()

        let change = try await peer.send("turn-off")
        try await eventually { coordinator.owner == nil }
        coordinator.reevaluate()

        #expect(change == "changed(generation: 2)")
        #expect(coordinator.ownerStatus == .nobody)
        #expect(!coordinator.armsTriggers)
        #expect(mac.armed == 0)

        let relaunched = mac.launchPortavoz()

        #expect(!relaunched.armsTriggers)
        #expect(try mac.state().owner == nil)

        await mac.comeBack(relaunched)

        #expect(relaunched.state == .owned)
        #expect(mac.armed == 1)
    }

    // MARK: Readiness

    @Test(arguments: ["microphone", "engine"])
    func aPeerNotReadyCannotTakeOwnershipAndPortavozKeepsIt(missing: String) async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        try await peer.send("missing \(missing)")

        let handoff = try await peer.send("take")

        #expect(handoff.hasPrefix("notAvailable"))
        #expect(coordinator.state == .owned)
        #expect(try mac.state().owner == CoexistenceID.portavoz)
        #expect(try mac.state().generation == 1)
    }

    @Test
    func anOwningPeerThatLosesAPermissionIsRefusedAndKeepsOwnership() async throws {
        let mac = try CoexistenceMac()
        let peer = try await mac.launchOwningPeer()
        let coordinator = mac.launchPortavoz()

        try await peer.send("missing microphone")

        #expect(try await peer.send("acquire global").hasPrefix("refused unavailable"))
        #expect(coordinator.state == .available)
        #expect(try mac.state().owner == CoexistenceID.secreteo)
    }

    // MARK: Dev and Release

    @Test
    func aDevPeerNeedsTheUserToTakeOwnershipFromRelease() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let dev = try mac.launchPeer(as: CoexistenceID.portavozDev)

        #expect(try await dev.send("claim") == "noChange")
        #expect(try await dev.send("take-unconfirmed") == "notConfirmed")
        #expect(coordinator.state == .owned)

        #expect(try await dev.send("take") == "completed(generation: 2)")

        try await eventually { coordinator.state == .available }
        #expect(refusal(coordinator) == .notOwner)
        #expect(try await dev.send("acquire global") == "admitted 2")
        #expect(refusal(coordinator) == .busy)
    }

    @Test
    func aDevLaunchNeverTakesOwnershipFromRelease() async throws {
        let mac = try CoexistenceMac()
        let release = try mac.launchPeer(as: CoexistenceID.portavoz)
        try await release.send("claim")

        let dev = mac.launchPortavoz(as: CoexistenceID.portavozDev)

        #expect(dev.state == .available)
        #expect(!dev.armsTriggers)
        #expect(try mac.state().owner == CoexistenceID.portavoz)
    }

    // MARK: A Portavoz from before the protocol

    @Test
    func anOlderPortavozWithDictationOnKeepsThisOneFromArmingUntilItQuits() async throws {
        let mac = try CoexistenceMac()
        mac.conditions.value.legacyPeerIsActive = true

        let coordinator = mac.launchPortavoz()

        #expect(coordinator.state == .unavailable(.legacyPeerActive))
        #expect(!coordinator.armsTriggers)
        #expect(refusal(coordinator) == .unavailable(.legacyPeerActive))
        let practice = try coordinator.admission.acquire(.practice).get()
        practice.release()

        mac.conditions.value.legacyPeerIsActive = false
        coordinator.reevaluate()

        #expect(coordinator.state == .owned)
        #expect(try mac.state().generation == 1)
    }

    @Test(arguments: [(false, true), (true, false)])
    func onlyAnotherPortavozBuildWithoutTheProtocolCountsAsOlder(example: (declares: Bool, isLegacy: Bool)) throws {
        let mac = try CoexistenceMac()
        let installed = try bundle(in: mac, named: "Portavoz", declaresProtocol: example.declares)

        let peers = DictationOwnershipCoordinator.legacyPeers(
            excluding: CoexistenceID.portavozDev,
            running: { [RunningApp(identifier: CoexistenceID.portavoz, bundleURL: installed)] },
            preferenceIsOn: { _ in true })

        #expect((peers.activePeer() == CoexistenceID.portavoz) == example.isLegacy)
    }

    @Test
    func anOlderPortavozWithDictationOffIsNotInTheWay() throws {
        let mac = try CoexistenceMac()
        let installed = try bundle(in: mac, named: "Portavoz", declaresProtocol: false)

        let peers = DictationOwnershipCoordinator.legacyPeers(
            excluding: CoexistenceID.portavozDev,
            running: { [RunningApp(identifier: CoexistenceID.portavoz, bundleURL: installed)] },
            preferenceIsOn: { _ in false })

        #expect(peers.activePeer() == nil)
    }

    // MARK: Exclusion

    @Test
    func sessionsInBothProcessesNeverOverlapAcrossHandoffs() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        try await peer.send("sessions")

        try await runLoggedSessions(coordinator, on: mac)
        #expect(try await peer.send("take") == "completed(generation: 2)")
        try await runLoggedSessions(coordinator, on: mac)
        await mac.comeBack(coordinator)
        try await runLoggedSessions(coordinator, on: mac)
        #expect(try await peer.send("take") == "completed(generation: 4)")
        try await eventually { mac.events().contains("enter \(peer.identifier)") }
        try await peer.send("stop-sessions")

        let events = mac.events()
        #expect(violations(in: events).isEmpty)
        #expect(events.contains("enter \(getpid())"))
    }

    @Test
    func theLogDoesSeeAnOverlapWhenThePeerSkipsItsLease() async throws {
        let mac = try CoexistenceMac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        let lease = try coordinator.admission.acquire(.global).get()
        mac.write("enter")

        try await peer.send("sessions unleased")
        try await eventually { mac.events().contains("enter \(peer.identifier)") }
        try await peer.send("stop-sessions")
        mac.write("exit")
        lease.release()

        #expect(violations(in: mac.events()).contains { $0.hasPrefix("overlap") })
    }

    // MARK: The peer process itself

    @Test
    func aCommandToADeadPeerFailsInsteadOfEndingTheRun() async throws {
        let mac = try CoexistenceMac()
        let peer = try mac.launchPeer()

        await peer.crash()

        #expect(throws: (any Error).self) { try peer.post("status") }
    }

    @Test
    func aCancelledWaitEndsAPeerThatNeverAnswers() async throws {
        let mac = try CoexistenceMac()
        let peer = try mac.launchPeer()
        peer.signal(SIGSTOP)

        let waiting = Task { try await peer.send("status") }
        waiting.cancel()

        #expect(try await waiting.value.isEmpty)
    }
}
