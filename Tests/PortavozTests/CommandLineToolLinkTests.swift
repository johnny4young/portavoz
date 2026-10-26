import Foundation
import PlatformKit
import XCTest

@testable import portavoz_app

final class CommandLineToolLinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-link-\(UUID().uuidString)")
        let tool = root.appendingPathComponent("Portavoz.app/Contents/Helpers/portavoz-cli")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tool.path, contents: Data(), attributes: [.posixPermissions: 0o755])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var link: CommandLineToolLink {
        .standard(appBundle: root.appendingPathComponent("Portavoz.app"), home: root.appendingPathComponent("home"))
    }

    func testInstallCreatesTheDirectoryAndLinkThenRemovesOnlyItsOwnLink() throws {
        XCTAssertTrue(link.toolExists)
        XCTAssertEqual(link.state(), .notInstalled)

        try link.install()
        XCTAssertEqual(link.state(), .installed)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: link.destination.path), link.tool.path)
        try link.install()
        XCTAssertEqual(link.state(), .installed, "installing again keeps one link")

        try link.remove()
        XCTAssertEqual(link.state(), .notInstalled)
        XCTAssertThrowsError(try link.remove())
    }

    func testAnotherLinkIsReplacedButNeverRemovedAndAFileIsNeverTouched() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: link.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: link.destination.path, withDestinationPath: "/usr/local/bin/old-portavoz-cli")
        XCTAssertEqual(link.state(), .linkedElsewhere("/usr/local/bin/old-portavoz-cli"))
        XCTAssertThrowsError(try link.remove()) { error in
            XCTAssertEqual(error as? CommandLineToolLink.LinkError, .notOurLink)
        }
        try link.install()
        XCTAssertEqual(link.state(), .installed)

        try manager.removeItem(at: link.destination)
        manager.createFile(atPath: link.destination.path, contents: Data("mine".utf8))
        XCTAssertEqual(link.state(), .blocked)
        XCTAssertThrowsError(try link.install()) { error in
            XCTAssertEqual(error as? CommandLineToolLink.LinkError, .destinationBlocked)
        }
        XCTAssertEqual(manager.contents(atPath: link.destination.path), Data("mine".utf8))
    }

    func testInstallRefusesWhenTheAppHasNoTool() throws {
        try FileManager.default.removeItem(at: link.tool)
        XCTAssertFalse(link.toolExists)
        XCTAssertThrowsError(try link.install()) { error in
            XCTAssertEqual(error as? CommandLineToolLink.LinkError, .toolMissing)
        }
    }

    func testOnlyTheToolNameStartsTheCommandLineTool() {
        XCTAssertTrue(CommandLineInvocation.runsCommandLineTool(["portavoz-cli", "mcp"]))
        XCTAssertTrue(CommandLineInvocation.runsCommandLineTool(["/opt/homebrew/bin/portavoz-cli"]))
        XCTAssertTrue(CommandLineInvocation.runsCommandLineTool(["/Applications/Portavoz.app/Contents/Helpers/portavoz-cli"]))
        XCTAssertFalse(CommandLineInvocation.runsCommandLineTool(["/Applications/Portavoz.app/Contents/MacOS/portavoz-app"]))
        XCTAssertFalse(CommandLineInvocation.runsCommandLineTool(["portavoz-cli-old", "mcp"]))
        XCTAssertFalse(CommandLineInvocation.runsCommandLineTool([""]))
        XCTAssertFalse(CommandLineInvocation.runsCommandLineTool([]))
    }

    @MainActor
    func testClientCommandsUseTheLinkOnceInstalled() async throws {
        let model = CommandLineToolModel(link: link)
        XCTAssertEqual(model.commandPath, link.tool.path)
        XCTAssertEqual(model.claudeCommand, "claude mcp add portavoz -- \"\(link.tool.path)\" mcp")

        model.install()
        XCTAssertEqual(model.state, .installed)
        XCTAssertEqual(model.commandPath, link.destination.path)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(model.mcpConfiguration.utf8)) as? [String: [String: [String: Any]]])
        XCTAssertEqual(json["mcpServers"]?["portavoz"]?["command"] as? String, link.destination.path)
        XCTAssertEqual(json["mcpServers"]?["portavoz"]?["args"] as? [String], ["mcp"])
        XCTAssertNil(model.failure)
    }
}
