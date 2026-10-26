import Foundation
import Observation
import PlatformKit

/// The Settings state for the bundled command-line tool: whether its link is
/// on the shell path, and the commands an MCP client needs.
@MainActor
@Observable
final class CommandLineToolModel {
    static let pathExport = #"export PATH="$HOME/.local/bin:$PATH""#

    private(set) var state = CommandLineToolLink.State.notInstalled
    private(set) var failure: String?
    @ObservationIgnored let link: CommandLineToolLink

    init(link: CommandLineToolLink) {
        self.link = link
        state = link.state()
    }

    var toolAvailable: Bool { link.toolExists }

    /// What an MCP client runs: the link once installed, otherwise the tool inside the app.
    var commandPath: String { state == .installed ? link.destination.path : link.tool.path }

    var claudeCommand: String { "claude mcp add portavoz -- \"\(commandPath)\" mcp" }

    var mcpConfiguration: String {
        let configuration = ["mcpServers": ["portavoz": ["command": commandPath, "args": ["mcp"]]]]
        let options: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? JSONSerialization.data(withJSONObject: configuration, options: options) else { return "" }
        return String(bytes: data, encoding: .utf8) ?? ""
    }

    func refresh() {
        state = link.state()
    }

    func install() {
        perform { try link.install() }
    }

    func remove() {
        perform { try link.remove() }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            failure = nil
        } catch CommandLineToolLink.LinkError.destinationBlocked {
            failure = L10n.text("A file Portavoz didn't create is already at ~/.local/bin/portavoz-cli.")
        } catch {
            failure = L10n.text("The command-line tool could not be installed.")
        }
        refresh()
    }

    /// The installed app's tool and the user's `~/.local/bin`. Disposable launches
    /// use a scratch directory instead, with a stand-in tool only when asked to.
    static func forCurrentLaunch(arguments: [String] = ProcessInfo.processInfo.arguments) -> CommandLineToolModel {
        guard arguments.contains("-use-temp-store") else {
            return CommandLineToolModel(link: .standard(
                appBundle: Bundle.main.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser))
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("portavoz-cli-\(UUID().uuidString)")
        let tool = scratch.appendingPathComponent("Portavoz.app/Contents/Helpers/portavoz-cli")
        if arguments.contains("-seed-command-line-tool") {
            try? FileManager.default.createDirectory(
                at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: tool.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }
        return CommandLineToolModel(link: CommandLineToolLink(
            tool: tool, destination: scratch.appendingPathComponent("home/.local/bin/portavoz-cli")))
    }
}
