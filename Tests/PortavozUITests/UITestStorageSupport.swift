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
        case unownedApplication
        case ambiguousApplication
    }

    private final class Session {
        let ownerID: UUID
        let scratch: UITestScratch
        var applications: [XCUIApplication] = []
        var launchedProcesses: [ObjectIdentifier: UITestProcessIdentity] = [:]

        init(ownerID: UUID) throws {
            self.ownerID = ownerID
            scratch = try UITestScratch()
        }
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

    /// Capture the process created by this registered proxy's successful launch.
    /// A bundle identifier alone is never authority to terminate a process.
    static func recordLaunchedProcess(_ application: XCUIApplication) throws {
        guard let owned = session,
              owned.applications.contains(where: { $0 === application }),
              application.launchArguments.contains("-use-temp-store")
        else { throw Failure.unownedApplication }
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: XCUIApplication.portavozUITestHostBundleIdentifier)
        guard candidates.count == 1,
              let process = UITestProcessIdentity(candidates[0])
        else { throw Failure.ambiguousApplication }
        let key = ObjectIdentifier(application)
        if let previous = owned.launchedProcesses[key], !previous.isTerminated {
            throw Failure.ambiguousApplication
        }
        owned.launchedProcesses[key] = process
    }

    private static func capturedProcessIsCurrent(_ process: UITestProcessIdentity) -> Bool {
        let candidates = NSRunningApplication.runningApplications(
            withBundleIdentifier: XCUIApplication.portavozUITestHostBundleIdentifier)
        return candidates.count == 1 && process.matches(candidates[0])
    }

    private static func terminateCapturedProcess(
        _ application: XCUIApplication,
        process: UITestProcessIdentity
    ) throws {
        if process.isTerminated { return }
        guard capturedProcessIsCurrent(process) else { throw Failure.ambiguousApplication }
        application.terminate()
    }

    /// End final disposal by requesting normal Quit of our captured process.
    /// Mid-journey recovery tests retain XCTest's abrupt terminate() calls.
    /// Observe exit rather than paying XCTest's fixed termination round trip;
    /// the original ten-second deadline and scratch-ownership checks remain.
    static func terminateLaunchedProcess(_ application: XCUIApplication) throws {
        guard let owned = session,
              owned.applications.contains(where: { $0 === application }),
              let process = owned.launchedProcesses[ObjectIdentifier(application)]
        else { throw Failure.unownedApplication }
        // An old proxy's XCTest state can resolve a later same-bundle launch.
        // Its captured process, not that bundle-wide proxy state, owns exit.
        if process.isTerminated { return }
        do {
            guard capturedProcessIsCurrent(process) else { throw Failure.ambiguousApplication }
            // The sandboxed XCTest runner cannot send AppKit's Quit Apple
            // event. Use the already-guarded native shortcut instead; never
            // activate a foreign receiver or enter an unowned modal to quit.
            // Any exposed modal conservatively keeps the original abrupt
            // disposal. No waiting, activation or key is needed to close it.
            let modals = application.descendants(matching: .any).matching(NSPredicate(
                format: "elementType == %lu OR elementType == %lu OR elementType == %lu",
                XCUIElement.ElementType.sheet.rawValue,
                XCUIElement.ElementType.alert.rawValue,
                XCUIElement.ElementType.dialog.rawValue))
            if modals.count > 0 {
                try terminateCapturedProcess(application, process: process)
            } else {
                let admission = application.typeKeyIfOwned(
                    XCUIKeyboardKey(rawValue: "q"), modifierFlags: .command,
                    bundleIdentifier: XCUIApplication.portavozUITestHostBundleIdentifier,
                    expectedProcess: process)
                if admission != .admitted {
                    try terminateCapturedProcess(application, process: process)
                }
            }
        }
        guard waitForUITestCondition(timeout: 10, {
            process.isTerminated && application.state == .notRunning
        }), application.waitForPortavozProcessExit() else {
            throw Failure.applicationStillRunning
        }
    }

    /// Ends the caller's own session. Returns `false` when that owner has no
    /// live session, so a guard never reports cleanup it did not perform.
    @discardableResult
    static func end(ownerID: UUID, normalQuit: Bool = false) throws -> Bool {
        guard let owned = session, owned.ownerID == ownerID else { return false }
        defer { session = nil }
        for application in owned.applications {
            let process = owned.launchedProcesses[ObjectIdentifier(application)]
            // A completed older launch must not wait for (or act on) another
            // participant that uses the same bundle identifier in this case.
            if process?.isTerminated == true { continue }
            // Only a completed, healthy case may request normal Quit of the
            // exact launch it owns. Interruption/failure callers default to
            // abrupt XCTest termination, as do unrecorded fixture launches.
            if application.state != .notRunning {
                if normalQuit, process != nil, application.state == .runningForeground {
                    try terminateLaunchedProcess(application)
                } else if let process {
                    try terminateCapturedProcess(application, process: process)
                } else {
                    application.terminate()
                }
            }
            guard waitForUITestCondition(timeout: 10, {
                application.state == .notRunning && process?.isTerminated != false
            }) else {
                // Preserve scratch if a participant could still be writing.
                throw Failure.applicationStillRunning
            }
        }
        // Check the bundle-wide inventory only after every owned launch has
        // exited, not while a later participant legitimately remains alive.
        if let application = owned.applications.first,
           !application.waitForPortavozProcessExit() {
            throw Failure.applicationStillRunning
        }
        try owned.scratch.remove()
        return true
    }
}
