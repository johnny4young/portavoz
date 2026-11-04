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
final class CoexistenceShared<Value: Sendable>: Sendable {
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
final class PeerProcess {
    let process = Process()
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
        // A write to a dead peer has to fail one test, not end the whole run with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
    }

    var identifier: Int32 { process.processIdentifier }

    @discardableResult
    func send(_ command: String) async throws -> String {
        try post(command)
        return try await reply()
    }

    func post(_ command: String) throws {
        try input.fileHandleForWriting.write(contentsOf: Data("\(command)\n".utf8))
    }

    /// An empty line means the peer is gone. Cancelling kills it, because a time limit cannot end a blocked read.
    func reply() async throws -> String {
        let handle = output.fileHandleForReading
        let process = process
        return try await withTaskCancellationHandler {
            try await Task.detached {
                var line = Data()
                while let byte = try handle.read(upToCount: 1), let first = byte.first, first != UInt8(ascii: "\n") {
                    line.append(first)
                }
                return String(bytes: line, encoding: .utf8) ?? ""
            }.value
        } onCancel: {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// Only while it runs, because the pid of a reaped process can already belong to another one.
    func signal(_ signal: Int32) {
        if process.isRunning { kill(process.processIdentifier, signal) }
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

enum CoexistenceID {
    static let portavoz = "app.portavoz.mac"
    static let portavozDev = "app.portavoz.mac.dev"
    static let secreteo = "com.johnny4young.secreteo"
    /// Only an app with existing users may claim at first run, which Secreteo never does.
    static let otherClaimant = "com.example.existing-users"
}

/// One Mac for a coexistence test: the scratch folder both apps share, and each launch of them.
@MainActor
final class CoexistenceMac {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("portavoz-coexistence-\(UUID().uuidString)", isDirectory: true)
    let notification = "app.portavoz.coexistence-tests.\(UUID().uuidString)"
    let conditions = CoexistenceShared(
        ParticipantConditions(preferenceIsOn: true, missingForReadiness: nil, legacyPeerIsActive: false))
    let clockOffset = CoexistenceShared<TimeInterval>(0)
    private let peers = CoexistenceShared<[Process]>([])
    var settle: () async -> Void = {}
    private(set) var armed = 0
    private(set) var disarmed = 0

    var root: URL { parent.appendingPathComponent("store", isDirectory: true) }
    var log: URL { parent.appendingPathComponent("events.log") }
    var stateFile: URL { root.appendingPathComponent("ownership.json") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Peers stop with the test: nothing else ends them until the whole run exits.
    deinit {
        for process in peers.value where process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        try? FileManager.default.removeItem(at: parent)
    }

    /// One launch of Portavoz. A second call on the same folder is a relaunch.
    func launchPortavoz(
        as identifier: String = CoexistenceID.portavoz, deadline: Duration = .seconds(10)
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
        as identifier: String = CoexistenceID.secreteo, deadline: Duration = .seconds(10),
        notification: String? = nil
    ) throws -> PeerProcess {
        let peer = try PeerProcess(
            participant: identifier, root: root, notification: notification ?? self.notification, log: log,
            deadline: deadline)
        peers.value.append(peer.process)
        return peer
    }

    /// The way a real peer comes to own dictation: a confirmed handoff from nobody.
    func launchOwningPeer() async throws -> PeerProcess {
        let peer = try launchPeer()
        let outcome = try await peer.send("take")
        try #require(outcome == "completed(generation: 1)")
        return peer
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

    /// Append-only, like the peer's, so file order is the order of events even if exclusion breaks.
    func write(_ event: String) {
        let descriptor = open(log.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        _ = "\(event) \(getpid())\n".withCString { Darwin.write(descriptor, $0, strlen($0)) }
        close(descriptor)
    }

    func events() -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

@MainActor
protocol CoexistenceSuite {}

extension CoexistenceSuite {
    /// Every way a log breaks exclusion: an `enter` during another session or a session that never ended.
    func violations(in events: [String]) -> [String] {
        var open = Set<String>()
        var found: [String] = []
        for event in events {
            let parts = event.split(separator: " ").map(String.init)
            guard parts.count == 2 else {
                found.append("malformed: \(event)")
                continue
            }
            if parts[0] == "enter" {
                if !open.isEmpty { found.append("overlap: \(event)") }
                open.insert(parts[1])
            } else {
                open.remove(parts[1])
            }
        }
        return found + open.map { "unfinished: \($0)" }
    }

    func eventually(_ condition: @MainActor () -> Bool) async throws {
        _ = await TestPolling.until(condition)
        try #require(condition())
    }

    func connect(
        _ harness: DictationControllerHarness, to coordinator: DictationOwnershipCoordinator
    ) -> DictationSessionDependencies {
        // The same wiring as the app: a live intent reaches the session in progress.
        coordinator.onIntentChange = { isLive in
            if isLive { harness.controller.ownershipIntentSeen() } else { harness.controller.ownershipIntentCleared() }
        }
        var dependencies = harness.dependencies
        dependencies.admission = coordinator.admission
        return dependencies
    }

    func acquire(_ coordinator: DictationOwnershipCoordinator
    ) -> Result<DictationLease, DictationAdmissionRefusal> {
        coordinator.admission.acquire(.global)
    }

    func refusal(_ coordinator: DictationOwnershipCoordinator) -> DictationAdmissionRefusal? {
        switch acquire(coordinator) {
        case .success(let lease):
            lease.release()
            return nil
        case .failure(let refusal):
            return refusal
        }
    }

    func runLoggedSessions(_ coordinator: DictationOwnershipCoordinator, on mac: CoexistenceMac) async throws {
        for _ in 0..<40 {
            if case .success(let lease) = acquire(coordinator) {
                mac.write("enter")
                try await Task.sleep(for: .microseconds(200))
                mac.write("exit")
                lease.release()
            }
            try await Task.sleep(for: .microseconds(200))
        }
    }

    func admissions(_ coordinator: DictationOwnershipCoordinator, _ peer: PeerProcess) async throws -> Int {
        let here = acquire(coordinator)
        let there = try await peer.send("acquire global")
        defer { try? here.get().release() }
        return [(try? here.get()) != nil, there.hasPrefix("admitted")].filter { $0 }.count
    }

    func bundle(in mac: CoexistenceMac, named name: String, declaresProtocol: Bool) throws -> URL {
        let bundle = mac.parent.appendingPathComponent("\(name).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = declaresProtocol ? [ProtocolDeclaration.infoKey: 1] : ["CFBundleName": name]
        try (info as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }
}
