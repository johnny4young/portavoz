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

    /// Ends the caller's own session. Returns `false` when that owner has no
    /// live session, so a guard never reports cleanup it did not perform.
    @discardableResult
    static func end(ownerID: UUID) throws -> Bool {
        guard let owned = session, owned.ownerID == ownerID else { return false }
        defer { session = nil }
        for application in owned.applications {
            if application.state != .notRunning { application.terminate() }
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
