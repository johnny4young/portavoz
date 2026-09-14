import Darwin
import XCTest

/// Owns each journey's scratch and prevents XCTest's fallback monitors from
/// making a permission decision when an unexpected window blocks an action.
@MainActor
class PortavozUITestCase: XCTestCase {
    private let storageOwnerID = UUID()

    override func setUp() async throws {
        try await super.setUp()
        try UITestStorage.begin(ownerID: storageOwnerID)
        addUIInterruptionMonitor(withDescription: "Stop without answering an unexpected interruption") { _ in
            self.stopForUnexpectedInterruption()
        }
    }

    override func tearDown() async throws {
        let cleanup = Result { try UITestStorage.end(ownerID: storageOwnerID) }
        try await super.tearDown()
        try cleanup.get()
    }

    private func stopForUnexpectedInterruption() -> Never {
        // Cleanup precedes the assertion: synchronous XCTest unwinds here,
        // whereas async XCTest can return and would try its default handler.
        let cleanup: String
        do {
            try UITestStorage.end(ownerID: storageOwnerID)
            cleanup = "complete"
        } catch {
            // Do not interpolate errors: they may contain a private file path.
            cleanup = "failed"
        }
        let message = "PORTAVOZ_UI_INTERRUPTION_BLOCKED cleanup=\(cleanup)"
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        continueAfterFailure = false
        record(XCTIssue(type: .assertionFailure, compactDescription: message))
        // Returning either Bool would resume the interrupted event or the
        // fallback stack. Stop only this test worker, never another process.
        exit(EXIT_FAILURE)
    }
}
