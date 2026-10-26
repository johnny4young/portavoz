#if DEBUG
import Darwin
import XCTest
@testable import portavoz_app

@MainActor
final class UITestOwnedExitTests: XCTestCase {
    func testOnlyExplicitDisposableDebugHostConfigurationIsEligible() async {
        let arguments = ["-use-temp-store", "-uitest-owned-exit"]
        let environment = ["TMPDIR": "/private/tmp/owned", "PORTAVOZ_UI_TEST_EXIT_NONCE": UUID().uuidString]
        let bundle = "app.portavoz.mac.uitest-host"
        XCTAssertNotNil(UITestOwnedExit.configuration(
            bundleIdentifier: bundle, arguments: arguments, environment: environment))
        for identifier in [nil, "app.portavoz.mac", "app.portavoz.mac.dev"] {
            XCTAssertNil(UITestOwnedExit.configuration(
                bundleIdentifier: identifier, arguments: arguments, environment: environment))
        }
        for flags in [[], ["-use-temp-store"], ["-uitest-owned-exit"]] {
            XCTAssertNil(UITestOwnedExit.configuration(
                bundleIdentifier: bundle, arguments: flags, environment: environment))
        }
        for variables in [[:], ["TMPDIR": "/"],
                          ["TMPDIR": "relative", "PORTAVOZ_UI_TEST_EXIT_NONCE": UUID().uuidString],
                          ["TMPDIR": "/private/tmp/owned", "PORTAVOZ_UI_TEST_EXIT_NONCE": "invalid"]] {
            XCTAssertNil(UITestOwnedExit.configuration(
                bundleIdentifier: bundle, arguments: arguments, environment: variables))
        }
    }

    func testRequestRequiresExactLaunchPayloadAndPrivateRegularFile() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = open(root.path, O_EVTONLY | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(directory, 0)
        defer { close(directory) }
        let expected = Data("\(UUID().uuidString):\(getpid())".utf8)
        let file = root.appendingPathComponent("request")
        func accepts() -> Bool {
            UITestOwnedExit.validRequest(directory: directory, name: "request", expected: expected)
        }
        XCTAssertFalse(accepts(), "No request is not authority to exit")
        try expected.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertTrue(accepts())
        try Data(repeating: 65, count: expected.count).write(to: file)
        XCTAssertFalse(accepts(), "Wrong nonce/PID must not exit")
        try expected.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        XCTAssertFalse(accepts(), "Shared request is not owned authority")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let linked = root.appendingPathComponent("linked")
        try FileManager.default.linkItem(at: file, to: linked)
        XCTAssertFalse(accepts(), "Multiple hard links are ambiguous ownership")
        try FileManager.default.removeItem(at: linked)
        XCTAssertTrue(accepts())
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(mkfifo(file.path, 0o600), 0)
        XCTAssertFalse(accepts(), "Nonblocking FIFO inspection must reject, not hang")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        XCTAssertFalse(accepts())
        try FileManager.default.removeItem(at: file)
        try expected.write(to: linked)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: linked)
        XCTAssertFalse(accepts(), "A symlink cannot supply authority")
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-exit-unit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return root
    }
}
#endif
