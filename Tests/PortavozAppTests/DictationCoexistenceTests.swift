import AppKit
import Darwin
import DictationOwnership
import Foundation
import PortavozCore
import Synchronization
import Testing

@testable import portavoz_app
@testable import PortavozTestSupport

private final class BundleAnchor {}

/// `Mutex` cannot be captured by a closure, and the protocol reads these from its own.
private final class Shared<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    var value: Value {
        get { mutex.withLock { $0 } }
        set { mutex.withLock { $0 = newValue } }
    }
}

/// Another dictation app on the same Mac, as a real process. Each command answers one line.
@MainActor
private final class PeerProcess {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()

    init(participant: String, root: URL, notification: String, log: URL, deadline: Duration) throws {
        let products = Bundle(for: BundleAnchor.self).bundleURL.deletingLastPathComponent()
        process.executableURL = products.appendingPathComponent("dictation-peer")
        let milliseconds = deadline.components.seconds * 1_000 + deadline.components.attoseconds / 1_000_000_000_000_000
        process.arguments = [
            "--participant", participant, "--root", root.path, "--notification", notification,
            "--log", log.path, "--deadline-ms", String(milliseconds)
        ]
        process.standardInput = input
        process.standardOutput = output
        try process.run()
    }

    var identifier: Int32 { process.processIdentifier }

    @discardableResult
    func send(_ command: String) async throws -> String {
        try input.fileHandleForWriting.write(contentsOf: Data("\(command)\n".utf8))
        let handle = output.fileHandleForReading
        return try await Task.detached {
            var line = Data()
            while let byte = try handle.read(upToCount: 1), let first = byte.first, first != UInt8(ascii: "\n") {
                line.append(first)
            }
            return String(decoding: line, as: UTF8.self)
        }.value
    }

    func signal(_ signal: Int32) {
        kill(process.processIdentifier, signal)
    }

    /// Returns once the process is gone, so the kernel has dropped its locks.
    func crash() async {
        signal(SIGKILL)
        let process = process
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                process.waitUntilExit()
                continuation.resume()
            }
        }
    }
}

/// The acceptance rows for two apps on one Mac: the real coordinator here, another app in its own
/// process, and the real locks in a scratch folder. Triggers and the microphone are test doubles.
@Suite(.serialized, .exclusiveArgumentDomain, .timeLimit(.minutes(1)))
@MainActor
struct DictationCoexistenceTests {
    private static let portavoz = "app.portavoz.mac"
    private static let portavozDev = "app.portavoz.mac.dev"
    private static let secreteo = "com.johnny4young.secreteo"

    @MainActor
    private final class Mac {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-coexistence-\(UUID().uuidString)", isDirectory: true)
        let notification = "app.portavoz.coexistence-tests.\(UUID().uuidString)"
        let conditions = Shared(
            ParticipantConditions(preferenceIsOn: true, missingForReadiness: nil, legacyPeerIsActive: false))
        let clockOffset = Shared<TimeInterval>(0)
        var settle: () async -> Void = {}
        private(set) var armed = 0
        private(set) var disarmed = 0

        var root: URL { parent.appendingPathComponent("store", isDirectory: true) }
        var log: URL { parent.appendingPathComponent("events.log") }
        var stateFile: URL { root.appendingPathComponent("ownership.json") }

        init() throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: parent) }

        /// One launch of Portavoz. A second call on the same folder is a relaunch.
        func launchPortavoz(
            as identifier: String = DictationCoexistenceTests.portavoz, deadline: Duration = .seconds(10)
        ) -> DictationOwnershipCoordinator {
            let conditions = conditions
            let clockOffset = clockOffset
            let ownership = DictationOwnership(
                participant: identifier, root: root, isSandboxed: false,
                conditions: { conditions.value },
                now: { Date().addingTimeInterval(clockOffset.value) },
                notificationName: notification,
                timings: OwnershipTimings(
                    changeDeadline: deadline, capturePoll: .milliseconds(5), armRetry: .milliseconds(5)))
            let coordinator = DictationOwnershipCoordinator(
                ownership: ownership, root: root, notificationName: notification
            ) { [weak self] in await self?.settle() }
            coordinator.start()
            return coordinator
        }

        func launchPeer(
            as identifier: String = DictationCoexistenceTests.secreteo, deadline: Duration = .seconds(10)
        ) throws -> PeerProcess {
            try PeerProcess(
                participant: identifier, root: root, notification: notification, log: log, deadline: deadline)
        }

        func comeBack(_ coordinator: DictationOwnershipCoordinator) async {
            await coordinator.comeBack(
                arm: { [self] in
                    armed += 1
                    return true
                },
                disarm: { [self] in disarmed += 1 })
        }

        func state() throws -> OwnershipState {
            try OwnershipState.decoded(from: Data(contentsOf: stateFile)).get()
        }

        func write(_ event: String) throws {
            let handle = try FileHandle(forWritingTo: logCreatedIfNeeded())
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(event) \(getpid())\n".utf8))
        }

        private func logCreatedIfNeeded() -> URL {
            if !FileManager.default.fileExists(atPath: log.path) {
                FileManager.default.createFile(atPath: log.path, contents: nil)
            }
            return log
        }

        func events() -> [String] {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    /// Every way a log breaks exclusion: an `enter` during another session or a session that never ended.
    private func violations(in events: [String]) -> [String] {
        var open = Set<String>()
        var found: [String] = []
        for event in events {
            let parts = event.split(separator: " ").map(String.init)
            if parts[0] == "enter" {
                if !open.isEmpty { found.append("overlap: \(event)") }
                open.insert(parts[1])
            } else {
                open.remove(parts[1])
            }
        }
        return found + open.map { "unfinished: \($0)" }
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        _ = await TestPolling.until(condition)
        try #require(condition())
    }

    private func dependencies(
        _ harness: DictationControllerHarness, _ coordinator: DictationOwnershipCoordinator
    ) -> DictationSessionDependencies {
        // The same wiring as the app: a live intent reaches the session in progress.
        coordinator.onIntentChange = { isLive in
            if isLive { harness.controller.ownershipIntentSeen() } else { harness.controller.ownershipIntentCleared() }
        }
        var dependencies = harness.dependencies
        dependencies.admission = coordinator.admission
        return dependencies
    }

    private func acquire(_ coordinator: DictationOwnershipCoordinator) -> Result<DictationLease, DictationAdmissionRefusal> {
        coordinator.admission.acquire(.global)
    }

    private func refusal(_ coordinator: DictationOwnershipCoordinator) -> DictationAdmissionRefusal? {
        switch acquire(coordinator) {
        case .success(let lease):
            lease.release()
            return nil
        case .failure(let refusal):
            return refusal
        }
    }

    private func runLoggedSessions(_ coordinator: DictationOwnershipCoordinator, on mac: Mac) async throws {
        for _ in 0..<40 {
            if case .success(let lease) = acquire(coordinator) {
                try mac.write("enter")
                try await Task.sleep(for: .microseconds(200))
                try mac.write("exit")
                lease.release()
            }
            try await Task.sleep(for: .microseconds(200))
        }
    }

    // MARK: Launch

    @Test(arguments: 1...5)
    func aSimultaneousLaunchLeavesOneOwnerAndOneAdmission(round: Int) async throws {
        let mac = try Mac()
        let peer = try mac.launchPeer()

        async let claim = peer.send("claim")
        let coordinator = mac.launchPortavoz()
        _ = try await claim
        coordinator.reevaluate()

        let state = try mac.state()
        #expect(state.generation == 1)
        #expect([Self.portavoz, Self.secreteo].contains(state.owner))
        let here = acquire(coordinator)
        let there = try await peer.send("acquire global")
        let admissions = [(try? here.get()) != nil, there.hasPrefix("admitted")].filter { $0 }.count
        #expect(admissions == 1)
        try? here.get().release()
    }

    @Test
    func aPeerSessionAloneMakesPortavozWaitWithoutTakingAnything() async throws {
        let mac = try Mac()
        let peer = try mac.launchPeer()
        try await peer.send("claim")
        let coordinator = mac.launchPortavoz()

        #expect(coordinator.state == .available)
        #expect(!coordinator.armsTriggers)
        #expect(coordinator.ownerStatus == .otherApp(identifier: Self.secreteo))
        #expect(refusal(coordinator) == .notOwner)
        #expect(try mac.state().owner == Self.secreteo)
    }

    // MARK: Toggling and going back

    @Test
    func aToggleThereAndBackCountsEachChangeAndNamesThePreviousOwner() async throws {
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        #expect(coordinator.state == .owned)
        #expect(try mac.state().generation == 1)

        let there = try await peer.send("take")
        try await eventually { coordinator.state == .available }

        #expect(there == "completed(generation: 2)")
        #expect(refusal(coordinator) == .notOwner)
        #expect(try mac.state().previous == Self.portavoz)

        await mac.comeBack(coordinator)

        #expect(coordinator.state == .owned)
        #expect(mac.armed == 1)
        #expect(try mac.state().generation == 3)
        #expect(try mac.state().previous == Self.secreteo)
        #expect(try await peer.send("status") == "available")
        #expect(try await peer.send("acquire global").hasPrefix("refused notOwner"))
    }

    @Test
    func aHandoffWaitsForAPeerSessionThatYields() async throws {
        let mac = try Mac()
        let peer = try mac.launchPeer()
        try await peer.send("claim")
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
        let mac = try Mac()
        let peer = try mac.launchPeer()
        try await peer.send("claim")
        let coordinator = mac.launchPortavoz(deadline: .milliseconds(100))
        #expect(try await peer.send("acquire global") == "admitted 1")

        await mac.comeBack(coordinator)

        #expect(coordinator.handoffProblem == .busy)
        #expect(coordinator.state == .available)
        let state = try mac.state()
        #expect(state.owner == Self.secreteo)
        #expect(state.generation == 1)
        #expect(state.intent == nil)
        #expect(try await peer.send("revalidate") == "true")
    }

    // MARK: A Portavoz session when the peer asks for ownership

    @Test
    func aSessionStillPreparingIsCancelledAndThePeerTakesOver() async throws {
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        var dependencies = dependencies(harness, coordinator)
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
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        var dependencies = dependencies(harness, coordinator)
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
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        let gate = PreparationGate()
        mac.settle = { await gate.wait() }
        let harness = DictationControllerHarness(text: "So we ship it tomorrow.")
        defer { harness.controller.cancel() }
        let dependencies = dependencies(harness, coordinator)
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
    func aReleaseAfterAPressRefusedByThePeerLeavesItsSessionAlone() async throws {
        let mac = try Mac()
        let peer = try mac.launchPeer()
        try await peer.send("claim")
        let coordinator = mac.launchPortavoz()
        #expect(try await peer.send("acquire global") == "admitted 1")
        let harness = DictationControllerHarness(text: "No borres estas notas.")
        let dependencies = dependencies(harness, coordinator)

        harness.controller.handleHotkeyPress(using: dependencies, at: harness.now)
        harness.controller.handleHotkeyRelease(at: harness.now.addingTimeInterval(5))

        #expect(harness.controller.phase == .idle)
        #expect(harness.insertions.isEmpty)
        #expect(try await peer.send("revalidate") == "true")
    }

    // MARK: Crashes

    @Test
    func aPeerKilledWhileHoldingItsLeaseKeepsOwnershipUntilTheUserChooses() async throws {
        let mac = try Mac()
        let peer = try mac.launchPeer()
        try await peer.send("claim")
        let coordinator = mac.launchPortavoz()
        #expect(try await peer.send("acquire global") == "admitted 1")

        await peer.crash()
        coordinator.reevaluate()

        #expect(refusal(coordinator) == .notOwner)
        #expect(coordinator.ownerStatus == .otherApp(identifier: Self.secreteo))
        #expect(!coordinator.armsTriggers)
        #expect(try mac.state().owner == Self.secreteo)

        await mac.comeBack(coordinator)

        #expect(coordinator.state == .owned)
        #expect(try mac.state().generation == 2)
    }

    @Test
    func aPeerKilledDuringPracticeFreesTheLockForTheOwner() async throws {
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        #expect(try await peer.send("acquire practice") == "admitted 1")
        #expect(refusal(coordinator) == .busy)

        await peer.crash()

        #expect(refusal(coordinator) == nil)
    }

    @Test
    func aPeerKilledBeforeItsCommitLeavesPortavozTheOwnerOnceTheIntentExpires() async throws {
        let mac = try Mac()
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
        #expect(state.owner == Self.portavoz)
        #expect(state.generation == 1)
        #expect(refusal(coordinator) == nil)
    }

    @Test
    func aPeerKilledAfterItsCommitStaysTheOwner() async throws {
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        try await peer.send("take")

        await peer.crash()
        try await eventually { coordinator.state == .available }

        #expect(!coordinator.armsTriggers)
        #expect(try mac.state().owner == Self.secreteo)
        #expect(refusal(coordinator) == .notOwner)
    }

    // MARK: Sleep and wake

    @Test
    func aPeerFrozenWithItsLeaseStaysExclusiveAndCarriesOn() async throws {
        let mac = try Mac()
        let peer = try mac.launchPeer()
        try await peer.send("claim")
        let coordinator = mac.launchPortavoz(deadline: .milliseconds(100))
        #expect(try await peer.send("acquire global") == "admitted 1")

        peer.signal(SIGSTOP)
        await mac.comeBack(coordinator)
        #expect(coordinator.handoffProblem == .busy)
        peer.signal(SIGCONT)

        #expect(try await peer.send("revalidate") == "true")
        #expect(try mac.state().owner == Self.secreteo)
    }

    @Test
    func anIntentThatExpiredDuringSleepIsIgnoredOnWake() async throws {
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let intent = OwnershipIntent(from: Self.portavoz, to: Self.secreteo, now: Date())
        let state = OwnershipState(owner: Self.portavoz, generation: 1, previous: nil, intent: intent)
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

    // MARK: Upgrade and uninstall

    @Test
    func aRelaunchKeepsTheOwnerWhicheverAppItIs() async throws {
        let mac = try Mac()
        var coordinator = mac.launchPortavoz()
        #expect(coordinator.state == .owned)
        coordinator = mac.launchPortavoz()
        #expect(coordinator.state == .owned)
        let peer = try mac.launchPeer()
        try await peer.send("take")

        coordinator = mac.launchPortavoz()

        #expect(coordinator.state == .available)
        #expect(try mac.state().owner == Self.secreteo)
        #expect(try mac.state().generation == 2)
    }

    @Test
    func aNewerStateFileFailsClosedAndStaysByteIdentical() async throws {
        let mac = try Mac()
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
    func aPeerRemovedFromTheMacLeavesNobodyAndPortavozDoesNotArmItself() async throws {
        let mac = try Mac()
        let peer = try mac.launchPeer()
        try await peer.send("claim")
        let coordinator = mac.launchPortavoz()

        try await peer.send("relinquish")
        try await eventually { coordinator.owner == nil }
        coordinator.reevaluate()

        #expect(coordinator.ownerStatus == .nobody)
        #expect(!coordinator.armsTriggers)
        #expect(mac.armed == 0)
        #expect(try mac.state().owner == nil)

        await mac.comeBack(coordinator)

        #expect(coordinator.state == .owned)
        #expect(mac.armed == 1)
    }

    @Test
    func aPeerRemovedWithDictationOffHereOffersNothing() async throws {
        let mac = try Mac()
        mac.conditions.value.preferenceIsOn = false
        let peer = try mac.launchPeer()
        try await peer.send("claim")
        let coordinator = mac.launchPortavoz()

        try await peer.send("relinquish")
        coordinator.reevaluate()

        #expect(coordinator.state == .off)
        #expect(coordinator.ownerStatus == .noNotice)
        #expect(refusal(coordinator) == .dictationOff)
        #expect(mac.armed == 0)
    }

    // MARK: Readiness

    @Test(arguments: ["microphone", "engine"])
    func aPeerNotReadyCannotTakeOwnershipAndPortavozKeepsIt(missing: String) async throws {
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        try await peer.send("missing \(missing)")

        let handoff = try await peer.send("take")

        #expect(handoff.hasPrefix("notAvailable"))
        #expect(coordinator.state == .owned)
        #expect(try mac.state().owner == Self.portavoz)
        #expect(try mac.state().generation == 1)
    }

    @Test
    func anOwningPeerThatLosesAPermissionIsRefusedAndKeepsOwnership() async throws {
        let mac = try Mac()
        let peer = try mac.launchPeer()
        try await peer.send("claim")
        let coordinator = mac.launchPortavoz()

        try await peer.send("missing microphone")

        #expect(try await peer.send("acquire global").hasPrefix("refused unavailable"))
        #expect(coordinator.state == .available)
        #expect(try mac.state().owner == Self.secreteo)
    }

    // MARK: Dev and Release

    @Test
    func aDevPeerNeedsTheUserToTakeOwnershipFromRelease() async throws {
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let dev = try mac.launchPeer(as: Self.portavozDev)

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
        let mac = try Mac()
        let release = try mac.launchPeer(as: Self.portavoz)
        try await release.send("claim")

        let dev = mac.launchPortavoz(as: Self.portavozDev)

        #expect(dev.state == .available)
        #expect(!dev.armsTriggers)
        #expect(try mac.state().owner == Self.portavoz)
    }

    // MARK: A Portavoz from before the protocol

    @Test
    func anOlderPortavozWithDictationOnKeepsThisOneFromArmingUntilItQuits() async throws {
        let mac = try Mac()
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

    // MARK: Exclusion

    @Test
    func sessionsInBothProcessesNeverOverlapAcrossHandoffs() async throws {
        let mac = try Mac()
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
        #expect(violations(in: events) == [])
        #expect(events.contains("enter \(getpid())"))
    }

    @Test
    func theLogDoesSeeAnOverlapWhenThePeerSkipsItsLease() async throws {
        let mac = try Mac()
        let coordinator = mac.launchPortavoz()
        let peer = try mac.launchPeer()
        let lease = try coordinator.admission.acquire(.global).get()
        try mac.write("enter")

        try await peer.send("sessions unleased")
        try await eventually { mac.events().contains("enter \(peer.identifier)") }
        try await peer.send("stop-sessions")
        try mac.write("exit")
        lease.release()

        #expect(violations(in: mac.events()).contains { $0.hasPrefix("overlap") })
    }
}
