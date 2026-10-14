import AppKit
import Foundation
import XCTest

/// One owner per serial test case, with independent directories for each app
/// launch and export. The app never receives the runner's protected TMPDIR.
@MainActor
enum UITestStorage {
    enum Failure: Error {
        case missingSession
        case overlappingSessions
        case applicationStillRunning
    }

    private final class Session {
        let ownerID: UUID
        let scratch: UITestScratch
        var applications: [XCUIApplication] = []
        var launches: [ObjectIdentifier: OwnedLaunch] = [:]

        init(ownerID: UUID) throws {
            self.ownerID = ownerID
            scratch = try UITestScratch()
        }
    }

    private struct OwnedLaunch {
        let process: NSRunningApplication
        let request: URL
        let declined: URL
        let payload: Data
    }

    private static var session: Session?

    static func begin(ownerID: UUID) throws {
        guard session == nil else { throw Failure.overlappingSessions }
        session = try Session(ownerID: ownerID)
    }

    static func makeDirectory() throws -> URL {
        guard let session else { throw Failure.missingSession }
        return try UITestScratch(parent: session.scratch.url).url
    }

    static func register(_ application: XCUIApplication) throws {
        guard let session else { throw Failure.missingSession }
        session.applications.append(application)
    }

    static func prepareLaunch(_ application: XCUIApplication) {
        guard let session,
              session.applications.contains(where: { $0 === application }),
              application.launchArguments.contains("-use-temp-store") else { return }
        session.launches.removeValue(forKey: ObjectIdentifier(application))
        if !application.launchArguments.contains("-uitest-owned-exit") {
            application.launchArguments.append("-uitest-owned-exit")
        }
        // Relaunching the same XCTest proxy must never consume an old request.
        application.launchEnvironment["PORTAVOZ_UI_TEST_EXIT_NONCE"] = UUID().uuidString
    }

    static func recordLaunch(_ application: XCUIApplication) {
        let processes = NSRunningApplication.runningApplications(
            withBundleIdentifier: XCUIApplication.portavozUITestHostBundleIdentifier)
        guard let session,
              session.applications.contains(where: { $0 === application }),
              let nonce = application.launchEnvironment["PORTAVOZ_UI_TEST_EXIT_NONCE"],
              let root = application.launchEnvironment["TMPDIR"],
              processes.count == 1,
              let process = processes.first,
              process.processIdentifier > 0, !process.isTerminated else { return }
        let directory = URL(fileURLWithPath: root, isDirectory: true)
        let ready = directory.appendingPathComponent("portavoz-uitest-exit-ready-\(nonce)")
        let expected = Data("\(nonce):\(process.processIdentifier)".utf8)
        guard (try? Data(contentsOf: ready)) == expected else { return }
        session.launches[ObjectIdentifier(application)] = OwnedLaunch(
            process: process,
            request: directory.appendingPathComponent("portavoz-uitest-exit-\(nonce)"),
            declined: directory.appendingPathComponent("portavoz-uitest-exit-declined-\(nonce)"),
            payload: expected)
    }

    enum FinishOutcome: Equatable {
        case appKitExit
        case alreadyExited
        case officialTermination
        case identityLost
    }

    @discardableResult
    static func finish(_ application: XCUIApplication, allowOwnedExit: Bool = false) -> FinishOutcome {
        if let launch = session?.launches[ObjectIdentifier(application)] {
            // Old proxies resolve a later launch of the same bundle. An ended
            // captured launch is not authority to terminate that later process.
            if launch.process.isTerminated { return .alreadyExited }
            guard stillOwns(launch.process) else { return .identityLost }
            if allowOwnedExit, publish(launch.payload, to: launch.request) {
                waitForUITestCondition(timeout: 10) {
                    launch.process.isTerminated || (try? Data(contentsOf: launch.declined)) == launch.payload
                }
                if launch.process.isTerminated { return .appKitExit }
            }
            // Revalidate even the official fallback. Identity loss is not
            // authority to terminate a replacement process through this proxy.
            if launch.process.isTerminated { return .alreadyExited }
            guard stillOwns(launch.process) else { return .identityLost }
        }
        if application.state != .notRunning { application.terminate() }
        return .officialTermination
    }

    private static func stillOwns(_ process: NSRunningApplication) -> Bool {
        guard let current = NSRunningApplication(processIdentifier: process.processIdentifier) else { return false }
        return !current.isTerminated && current.isEqual(process)
    }

    private static func publish(_ data: Data, to destination: URL) -> Bool {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("portavoz-uitest-exit-stage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        guard FileManager.default.createFile(atPath: staging.path, contents: data,
                                            attributes: [.posixPermissions: 0o600]) else { return false }
        do {
            try FileManager.default.moveItem(at: staging, to: destination)
            return true
        } catch { return false }
    }

    /// Ends the caller's own session. Returns `false` when that owner has no
    /// live session, so a guard never reports cleanup it did not perform.
    @discardableResult
    static func end(ownerID: UUID, allowOwnedExit: Bool = false) throws -> Bool {
        guard let owned = session, owned.ownerID == ownerID else { return false }
        defer { session = nil }
        for application in owned.applications {
            guard finish(application, allowOwnedExit: allowOwnedExit) != .identityLost else {
                throw Failure.applicationStillRunning
            }
        }
        // All captured launches finish before a stale proxy observes the
        // bundle's final state; otherwise it can resolve a later owned launch.
        for application in owned.applications {
            guard application.wait(for: .notRunning, timeout: 10),
                  application.waitForPortavozProcessExit() else {
                // Preserve scratch if a participant could still be writing.
                throw Failure.applicationStillRunning
            }
        }
        try owned.scratch.remove()
        return true
    }
}
