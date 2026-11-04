import Darwin
import DictationOwnership
import Foundation
import Synchronization

/// Another dictation app on the same Mac, as a real process for the coexistence tests. It takes one
/// command per line on stdin, answers one line on stdout, and exits when its parent closes stdin.
@main
struct DictationPeer {
    private static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: "--\(name)"),
              index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static func main() async {
        let peer = Peer(
            participant: argument("participant") ?? "",
            root: URL(fileURLWithPath: argument("root") ?? ""),
            notificationName: argument("notification") ?? "",
            log: argument("log") ?? "",
            deadline: .milliseconds(Int(argument("deadline-ms") ?? "") ?? 10_000))
        do {
            for try await line in FileHandle.standardInput.bytes.lines {
                print(await peer.run(line.split(separator: " ").map(String.init)))
                fflush(stdout)
            }
        } catch {
            exit(1)
        }
    }
}

private struct Triggers: OwnershipTriggers {
    var diesWhenArming = false

    func arm() async -> Bool {
        if diesWhenArming { kill(getpid(), SIGKILL) }
        return true
    }

    func disarm() async {}
}

/// `Mutex` cannot be captured by a closure, and these two are read from callbacks.
private final class Shared<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) {
        mutex = Mutex(value)
    }

    func withLock<Result: Sendable>(_ body: @Sendable (inout Value) -> Result) -> Result {
        mutex.withLock { body(&$0) }
    }
}

private final class Peer: Sendable {
    private let ownership: DictationOwnership
    private let conditions = Shared(
        ParticipantConditions(preferenceIsOn: true, missingForReadiness: nil, legacyPeerIsActive: false))
    private let lease = Shared<OwnershipLease?>(nil)
    private let sessionsShouldStop = Mutex(false)
    private let observer = Mutex<OwnershipObserver?>(nil)
    private let sessions = Mutex<Task<Void, Never>?>(nil)
    private let log: String

    init(participant: String, root: URL, notificationName: String, log: String, deadline: Duration) {
        self.log = log
        let conditions = conditions
        ownership = DictationOwnership(
            participant: participant, root: root, isSandboxed: false,
            conditions: { conditions.withLock { $0 } },
            notificationName: notificationName,
            timings: OwnershipTimings(
                changeDeadline: deadline, capturePoll: .milliseconds(5), armRetry: .milliseconds(5)))
    }

    func run(_ words: [String]) async -> String {
        switch words.first {
        case "status": return String(describing: ownership.status())
        case "claim": return String(describing: ownership.claimAtFirstRun())
        case "acquire": return acquire(words.last == "practice" ? .practice : .global)
        case "revalidate": return String(lease.withLock { $0?.revalidate() ?? false })
        case "release":
            lease.withLock { held in
                held?.release()
                held = nil
            }
            return "released"
        case "missing":
            let missing = words.last
            conditions.withLock { $0.missingForReadiness = missing }
            return "ok"
        case "turn-off":
            conditions.withLock { $0.preferenceIsOn = false }
            return String(describing: await ownership.turnOff())
        default: return await runLongCommand(words)
        }
    }

    private func runLongCommand(_ words: [String]) async -> String {
        switch words.first {
        case "take": return String(describing: await ownership.takeOwnership(userConfirmed: true, triggers: Triggers()))
        case "take-unconfirmed":
            return String(describing: await ownership.takeOwnership(userConfirmed: false, triggers: Triggers()))
        case "take-and-die-arming":
            return String(describing: await ownership.takeOwnership(
                userConfirmed: true, triggers: Triggers(diesWhenArming: true)))
        case "yield-on-intent": return await yieldOnIntent()
        case "sessions": return startSessions(leased: words.last != "unleased")
        case "stop-sessions": return await stopSessions()
        default: return "unknown"
        }
    }

    private func acquire(_ kind: LeaseKind) -> String {
        switch ownership.acquire(kind) {
        case .admitted(let admitted):
            lease.withLock { $0 = admitted }
            return "admitted \(admitted.generation)"
        case .refused(let refusal):
            return "refused \(refusal)"
        }
    }

    /// A well-behaved holder: it ends its session when it sees another app asking.
    private func yieldOnIntent() async -> String {
        let lease = lease
        let observer = OwnershipObserver(ownership: ownership) { snapshot in
            guard snapshot.intent != nil else { return }
            lease.withLock { held in
                held?.release()
                held = nil
            }
        }
        self.observer.withLock { $0 = observer }
        await observer.start()
        await observer.setHoldingLease(true)
        return "watching"
    }

    private func startSessions(leased: Bool) -> String {
        let task = Task.detached { [self] in
            while !sessionsShouldStop.withLock({ $0 }) {
                runSession(leased: leased)
                usleep(200)
            }
        }
        sessions.withLock { $0 = task }
        return "started"
    }

    private func runSession(leased: Bool) {
        guard leased else {
            write("enter")
            usleep(200)
            write("exit")
            return
        }
        guard case .admitted(let admitted) = ownership.acquire(.global) else { return }
        write("enter")
        usleep(200)
        write("exit")
        admitted.release()
    }

    private func stopSessions() async -> String {
        sessionsShouldStop.withLock { $0 = true }
        await sessions.withLock { $0 }?.value
        return "stopped"
    }

    /// Through one append-only file shared with the test, so file order is the order of events.
    private func write(_ event: String) {
        let descriptor = open(log, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        _ = "\(event) \(getpid())\n".withCString { Darwin.write(descriptor, $0, strlen($0)) }
        close(descriptor)
    }
}
